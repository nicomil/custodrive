/* Image-only experiment. This program cannot open block or character devices. */
#include "OpenHDDNTFS.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/device_io.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

enum { CHUNK = 65536 };

/*
 * Test-only volatile device cache. Writes acknowledged by pwrite stay in
 * memory until sync; selected writes may reach the image earlier. _exit()
 * drops every cached write, unlike merely killing a process that wrote into
 * the host page cache. This harness only runs after the private-image checks.
 */
enum { SIM_CACHE_LIMIT = 256 * 1024 * 1024 };

typedef struct {
    s64 offset;
    s64 length;
    unsigned char *bytes;
    s64 durable_prefix;
} SimWrite;

typedef struct {
    struct ntfs_device_operations *base;
    SimWrite *writes;
    size_t write_count;
    size_t write_capacity;
    uint64_t accepted_bytes;
    uint64_t write_calls;
    uint64_t sync_calls;
    uint64_t persist_every;
    uint64_t crash_after_write;
    uint64_t partial_persist_at;
    uint64_t partial_persist_bytes;
    uint64_t crash_during_sync_after;
    int reverse_flush;
    int trace_fd;
    int active;
} CacheSim;

static CacheSim cache_sim = {.trace_fd = -1};

static uint64_t positive_env(const char *name)
{
    const char *value = getenv(name);
    if (!value || !*value) return 0;
    errno = 0;
    char *end = NULL;
    unsigned long long parsed = strtoull(value, &end, 10);
    return !errno && end != value && !*end ? (uint64_t)parsed : 0;
}

static void sim_trace(const char *format, ...)
{
    if (cache_sim.trace_fd < 0) return;
    char line[256];
    va_list args;
    va_start(args, format);
    int length = vsnprintf(line, sizeof(line), format, args);
    va_end(args);
    if (length <= 0 || (size_t)length >= sizeof(line)) return;
    size_t done = 0;
    while (done < (size_t)length) {
        ssize_t n = write(cache_sim.trace_fd, line + done,
                          (size_t)length - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return;
        done += (size_t)n;
    }
    (void)fsync(cache_sim.trace_fd);
}

static int sim_persist_bytes(struct ntfs_device *device, SimWrite *entry,
                             s64 length)
{
    if (length < 0 || length > entry->length) { errno = EINVAL; return -1; }
    for (s64 done = entry->durable_prefix; done < length; ) {
        s64 n = cache_sim.base->pwrite(device, entry->bytes + done,
                                       length - done, entry->offset + done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (!n) errno = EIO; return -1; }
        done += n;
    }
    if (length > entry->durable_prefix) entry->durable_prefix = length;
    return 0;
}

static void sim_apply_overlay(void *buffer, s64 count, s64 offset)
{
    if (count <= 0) return;
    s64 end = offset + count;
    for (size_t i = 0; i < cache_sim.write_count; ++i) {
        SimWrite *entry = &cache_sim.writes[i];
        s64 entry_end = entry->offset + entry->length;
        s64 overlap_start = offset > entry->offset ? offset : entry->offset;
        s64 overlap_end = end < entry_end ? end : entry_end;
        if (overlap_start < overlap_end)
            memcpy((unsigned char *)buffer + (overlap_start - offset),
                   entry->bytes + (overlap_start - entry->offset),
                   (size_t)(overlap_end - overlap_start));
    }
}

static s64 sim_pread(struct ntfs_device *device, void *buffer, s64 count,
                     s64 offset)
{
    s64 result = cache_sim.base->pread(device, buffer, count, offset);
    if (result > 0) sim_apply_overlay(buffer, result, offset);
    return result;
}

static int sim_reserve_write(void)
{
    if (cache_sim.write_count < cache_sim.write_capacity) return 0;
    size_t next = cache_sim.write_capacity ? cache_sim.write_capacity * 2 : 32;
    if (next < cache_sim.write_capacity || next > SIZE_MAX / sizeof(SimWrite)) {
        errno = EOVERFLOW;
        return -1;
    }
    SimWrite *grown = realloc(cache_sim.writes, next * sizeof(SimWrite));
    if (!grown) return -1;
    cache_sim.writes = grown;
    cache_sim.write_capacity = next;
    return 0;
}

static s64 sim_pwrite(struct ntfs_device *device, const void *buffer,
                      s64 count, s64 offset)
{
    if (count < 0 || offset < 0 ||
        (uint64_t)count > SIM_CACHE_LIMIT - cache_sim.accepted_bytes) {
        errno = ENOMEM;
        return -1;
    }
    if (sim_reserve_write()) return -1;
    unsigned char *copy = malloc((size_t)(count ? count : 1));
    if (!copy) return -1;
    if (count) memcpy(copy, buffer, (size_t)count);
    SimWrite *entry = &cache_sim.writes[cache_sim.write_count++];
    *entry = (SimWrite){.offset = offset, .length = count, .bytes = copy};
    cache_sim.accepted_bytes += (uint64_t)count;
    uint64_t call = ++cache_sim.write_calls;
    sim_trace("ACCEPT write=%llu offset=%lld length=%lld\n",
              (unsigned long long)call, (long long)offset, (long long)count);

    s64 persist_length = 0;
    if (cache_sim.persist_every && call % cache_sim.persist_every == 0)
        persist_length = count;
    if (cache_sim.partial_persist_at == call) {
        s64 partial = (s64)cache_sim.partial_persist_bytes;
        if (partial > count) partial = count;
        if (partial > persist_length) persist_length = partial;
    }
    if (persist_length && sim_persist_bytes(device, entry, persist_length))
        return -1;
    if (persist_length && cache_sim.base->sync(device)) return -1;
    if (persist_length)
        sim_trace("PERSIST write=%llu bytes=%lld\n",
                  (unsigned long long)call, (long long)persist_length);

    if (cache_sim.crash_after_write == call) {
        sim_trace("POWER_LOSS after-write=%llu\n", (unsigned long long)call);
        _exit(86);
    }
    return count;
}

static int sim_sync(struct ntfs_device *device)
{
    uint64_t sync_number = ++cache_sim.sync_calls;
    sim_trace("SYNC_BEGIN sync=%llu queued=%zu order=%s\n",
              (unsigned long long)sync_number, cache_sim.write_count,
              cache_sim.reverse_flush ? "reverse" : "forward");
    uint64_t persisted_in_sync = 0;
    for (size_t step = 0; step < cache_sim.write_count; ++step) {
        size_t index = cache_sim.reverse_flush ?
            cache_sim.write_count - step - 1 : step;
        SimWrite *entry = &cache_sim.writes[index];
        if (sim_persist_bytes(device, entry, entry->length)) return -1;
        ++persisted_in_sync;
        if (cache_sim.crash_during_sync_after == persisted_in_sync) {
            if (cache_sim.base->sync(device)) return -1;
            sim_trace("POWER_LOSS during-sync=%llu after=%llu\n",
                      (unsigned long long)sync_number,
                      (unsigned long long)persisted_in_sync);
            _exit(86);
        }
    }
    if (cache_sim.base->sync(device)) return -1;
    sim_trace("SYNC_END sync=%llu persisted=%zu\n",
              (unsigned long long)sync_number, cache_sim.write_count);
    for (size_t i = 0; i < cache_sim.write_count; ++i)
        free(cache_sim.writes[i].bytes);
    cache_sim.write_count = 0;
    cache_sim.accepted_bytes = 0;
    return 0;
}

static s64 sim_read(struct ntfs_device *device, void *buffer, s64 count)
{
    s64 offset = cache_sim.base->seek(device, 0, SEEK_CUR);
    if (offset < 0) return -1;
    s64 result = cache_sim.base->read(device, buffer, count);
    if (result > 0) sim_apply_overlay(buffer, result, offset);
    return result;
}

static s64 sim_write(struct ntfs_device *device, const void *buffer, s64 count)
{
    s64 offset = cache_sim.base->seek(device, 0, SEEK_CUR);
    if (offset < 0) return -1;
    s64 result = sim_pwrite(device, buffer, count, offset);
    if (result > 0 && cache_sim.base->seek(device, offset + result, SEEK_SET) < 0)
        return -1;
    return result;
}

static int sim_open(struct ntfs_device *device, int flags)
{
    return cache_sim.base->open(device, flags);
}

static int sim_close(struct ntfs_device *device)
{
    if (sim_sync(device)) return -1;
    return cache_sim.base->close(device);
}

static s64 sim_seek(struct ntfs_device *device, s64 offset, int whence)
{
    return cache_sim.base->seek(device, offset, whence);
}

static int sim_stat(struct ntfs_device *device, struct stat *out)
{
    return cache_sim.base->stat(device, out);
}

static int sim_ioctl(struct ntfs_device *device, unsigned long request,
                     void *argument)
{
    return cache_sim.base->ioctl(device, request, argument);
}

static struct ntfs_device_operations simulated_device_ops = {
    .open = sim_open,
    .close = sim_close,
    .seek = sim_seek,
    .read = sim_read,
    .write = sim_write,
    .pread = sim_pread,
    .pwrite = sim_pwrite,
    .sync = sim_sync,
    .stat = sim_stat,
    .ioctl = sim_ioctl
};

static int sim_attach(ntfs_volume *volume, const char *trace_path)
{
    const char *enabled = getenv("OPENHDD_SIMULATE_CACHE");
    if (!enabled || strcmp(enabled, "1")) return 0;
    cache_sim.base = volume->dev->d_ops;
    cache_sim.persist_every = positive_env("OPENHDD_SIM_PERSIST_EVERY");
    cache_sim.crash_after_write = positive_env("OPENHDD_SIM_CRASH_AFTER_PWRITE");
    cache_sim.partial_persist_at = positive_env("OPENHDD_SIM_PARTIAL_PERSIST_AT");
    cache_sim.partial_persist_bytes = positive_env("OPENHDD_SIM_PARTIAL_PERSIST_BYTES");
    cache_sim.crash_during_sync_after = positive_env("OPENHDD_SIM_CRASH_DURING_SYNC_AFTER");
    const char *order = getenv("OPENHDD_SIM_FLUSH_ORDER");
    cache_sim.reverse_flush = order && !strcmp(order, "reverse");
    if (trace_path && *trace_path) {
        cache_sim.trace_fd = open(trace_path, O_WRONLY | O_CREAT | O_EXCL |
                                  O_NOFOLLOW, 0600);
        if (cache_sim.trace_fd < 0) return -1;
    }
    cache_sim.active = 1;
    volume->dev->d_ops = &simulated_device_ops;
    sim_trace("CACHE_SIM attached persist-every=%llu flush=%s\n",
              (unsigned long long)cache_sim.persist_every,
              cache_sim.reverse_flush ? "reverse" : "forward");
    return 0;
}

static void sim_destroy(void)
{
    for (size_t i = 0; i < cache_sim.write_count; ++i)
        free(cache_sim.writes[i].bytes);
    free(cache_sim.writes);
    cache_sim.writes = NULL;
    cache_sim.write_count = cache_sim.write_capacity = 0;
    if (cache_sim.trace_fd >= 0) close(cache_sim.trace_fd);
    cache_sim.trace_fd = -1;
    cache_sim.active = 0;
}

static int64_t read_block(void *opaque, uint64_t offset, void *buffer,
                          uint64_t length)
{
    int fd = *(int *)opaque;
    ssize_t n = pread(fd, buffer, (size_t)length, (off_t)offset);
    return n < 0 ? -1 : n;
}

static int plain_filename(const char *name)
{
    size_t length = strlen(name);
    if (!length || length > 255 || !strcmp(name, ".") || !strcmp(name, ".."))
        return 0;
    for (size_t i = 0; i < length; ++i)
        if ((unsigned char)name[i] < 32 || strchr("/\\:*?\"<>|", name[i]))
            return 0;
    return 1;
}

static int private_image_path(const char *path, const struct stat *image)
{
    if (!S_ISREG(image->st_mode) || image->st_uid != geteuid() ||
        (image->st_mode & 077) || image->st_nlink != 1)
        return 0;
    char *parent = strdup(path);
    if (!parent) return 0;
    char *slash = strrchr(parent, '/');
    if (!slash || slash == parent) { free(parent); return 0; }
    *slash = 0;
    struct stat directory;
    int safe = !lstat(parent, &directory) && S_ISDIR(directory.st_mode) &&
               directory.st_uid == geteuid() && !(directory.st_mode & 077);
    free(parent);
    return safe;
}

static int preflight(const char *path, const struct stat *image_stat,
                     const char *name)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat current;
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int result = -1;
    if (fstat(fd, &current) || !S_ISREG(current.st_mode) ||
        current.st_dev != image_stat->st_dev ||
        current.st_ino != image_stat->st_ino || current.st_size < 4096)
        goto out;
    if (oh_ntfs_open(read_block, &fd, (uint64_t)current.st_size,
                     &volume, &warnings) || warnings) {
        errno = warnings ? EBUSY : EIO;
        goto out;
    }
    OHNTFSItem existing;
    int lookup = oh_ntfs_lookup(volume, FILE_root, name, &existing);
    if (lookup != ENOENT) {
        errno = lookup ? lookup : EEXIST;
        goto out;
    }
    result = 0;
out:
    oh_ntfs_close(volume);
    close(fd);
    return result;
}

static int verify(const char *image, const struct stat *image_stat,
                  const char *name, uint64_t expected_size,
                  const unsigned char expected_hash[CC_SHA256_DIGEST_LENGTH])
{
    int fd = open(image, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return -1;
    struct stat current;
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    OHNTFSItem item;
    unsigned char *buffer = NULL;
    unsigned char actual_hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX digest;
    int result = -1;
    if (fstat(fd, &current) || !S_ISREG(current.st_mode) ||
        current.st_dev != image_stat->st_dev || current.st_ino != image_stat->st_ino ||
        current.st_size != image_stat->st_size)
        goto out;
    if (oh_ntfs_open(read_block, &fd, (uint64_t)current.st_size,
                     &volume, &warnings) || warnings)
        goto out;
    if (oh_ntfs_lookup(volume, FILE_root, name, &item) || item.kind != 1 ||
        item.size != expected_size)
        goto out;
    buffer = malloc(CHUNK);
    if (!buffer || !CC_SHA256_Init(&digest)) goto out;
    for (uint64_t offset = 0; offset < expected_size; ) {
        uint64_t count = expected_size - offset;
        if (count > CHUNK) count = CHUNK;
        int64_t n = oh_ntfs_read(volume, item.inode, offset, buffer, count);
        if (n != (int64_t)count || !CC_SHA256_Update(&digest, buffer, (CC_LONG)n))
            goto out;
        offset += count;
    }
    if (!CC_SHA256_Final(actual_hash, &digest) ||
        memcmp(actual_hash, expected_hash, sizeof(actual_hash)))
        goto out;
    result = 0;
out:
    free(buffer);
    oh_ntfs_close(volume);
    close(fd);
    return result;
}

int main(int argc, char **argv)
{
    if (argc != 4 || !plain_filename(argv[3])) {
        fputs("usage: offline_image_writer IMAGE_FILE SOURCE_FILE NEW_ROOT_FILENAME\n", stderr);
        return 2;
    }
    setlocale(LC_ALL, "");
    ntfs_log_set_handler(ntfs_log_handler_null);
    struct stat image_stat, source_stat, source_after;
    if (lstat(argv[1], &image_stat) || !private_image_path(argv[1], &image_stat) ||
        lstat(argv[2], &source_stat) || !S_ISREG(source_stat.st_mode) ||
        source_stat.st_size < 0 || preflight(argv[1], &image_stat, argv[3])) {
        fputs("preflight refused\n", stderr);
        return 1;
    }
    int source = open(argv[2], O_RDONLY | O_NOFOLLOW);
    if (source < 0 || fstat(source, &source_after) ||
        source_after.st_dev != source_stat.st_dev ||
        source_after.st_ino != source_stat.st_ino ||
        source_after.st_size != source_stat.st_size ||
        (source_after.st_dev == image_stat.st_dev &&
         source_after.st_ino == image_stat.st_ino)) {
        if (source >= 0) close(source);
        fputs("source changed\n", stderr);
        return 1;
    }

    ntfs_volume *volume = NULL;
    int image_fd = -1;
    ntfs_inode *root = NULL, *created = NULL;
    ntfs_attr *data = NULL;
    ntfschar *unicode_name = NULL;
    unsigned char *buffer = NULL;
    unsigned char written_hash[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX digest;
    int status = 1;
    int stage = 1;

    /* Bind the writer to a verified regular-file descriptor, not a replaceable path. */
    image_fd = open(argv[1], O_RDWR | O_NOFOLLOW);
    struct stat opened_image;
    if (image_fd < 0 || fstat(image_fd, &opened_image) ||
        !S_ISREG(opened_image.st_mode) ||
        opened_image.st_dev != image_stat.st_dev ||
        opened_image.st_ino != image_stat.st_ino ||
        opened_image.st_size != image_stat.st_size)
        goto out;
    stage = 2;
    volume = ntfs_mount(argv[1], NTFS_MNT_EXCLUSIVE);
    if (!volume || (volume->flags & VOLUME_IS_DIRTY) || NVolReadOnly(volume))
        goto out;
    if (sim_attach(volume, getenv("OPENHDD_SIM_TRACE"))) goto out;
    struct stat ntfs_handle;
    if (volume->dev->d_ops->stat(volume->dev, &ntfs_handle) ||
        !S_ISREG(ntfs_handle.st_mode) ||
        ntfs_handle.st_dev != image_stat.st_dev ||
        ntfs_handle.st_ino != image_stat.st_ino)
        goto out;
    ntfs_inode *existing = ntfs_pathname_to_inode(volume, NULL, argv[3]);
    if (existing) {
        ntfs_inode_close(existing);
        errno = EEXIST;
        goto out;
    }
    if (errno != ENOENT) goto out;
    root = ntfs_inode_open(volume, FILE_root);
    stage = 3;
    if (!root) goto out;
    int name_length = ntfs_mbstoucs(argv[3], &unicode_name);
    if (name_length <= 0 || name_length > 255) goto out;
    created = ntfs_create(root, const_cpu_to_le32(0), unicode_name,
                          (u8)name_length, S_IFREG);
    if (!created) goto out;
    int root_close_error = ntfs_inode_close(root);
    root = NULL;
    if (root_close_error) goto out;
    data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
    if (!data) {
        if (errno != ENOENT ||
            ntfs_attr_add(created, AT_DATA, AT_UNNAMED, 0, NULL, 0))
            goto out;
        data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
        if (!data) goto out;
    }
    if (ntfs_attr_truncate_solid(data, source_stat.st_size)) goto out;
    stage = 4;
    buffer = malloc(CHUNK);
    if (!buffer || !CC_SHA256_Init(&digest)) goto out;
    for (uint64_t offset = 0; offset < (uint64_t)source_stat.st_size; ) {
        if (offset && getenv("OPENHDD_TEST_FAIL_AFTER_FIRST_CHUNK")) {
            errno = EIO;
            goto out;
        }
        size_t count = (uint64_t)source_stat.st_size - offset;
        if (count > CHUNK) count = CHUNK;
        ssize_t n = read(source, buffer, count);
        if (n != (ssize_t)count || !CC_SHA256_Update(&digest, buffer, (CC_LONG)n))
            goto out;
        for (ssize_t done = 0; done < n; ) {
            s64 wrote = ntfs_attr_pwrite(data, (s64)(offset + done), n - done,
                                          buffer + done);
            if (wrote <= 0) goto out;
            done += wrote;
        }
        offset += count;
    }
    if (fstat(source, &source_after) ||
        source_after.st_size != source_stat.st_size ||
        source_after.st_mtimespec.tv_sec != source_stat.st_mtimespec.tv_sec ||
        source_after.st_mtimespec.tv_nsec != source_stat.st_mtimespec.tv_nsec ||
        source_after.st_ctimespec.tv_sec != source_stat.st_ctimespec.tv_sec ||
        source_after.st_ctimespec.tv_nsec != source_stat.st_ctimespec.tv_nsec ||
        !CC_SHA256_Final(written_hash, &digest)) goto out;
    ntfs_attr_close(data);
    data = NULL;
    int created_close_error = ntfs_inode_close(created);
    created = NULL;
    if (created_close_error) goto out;
    stage = 5;
    int unmount_error = ntfs_umount(volume, FALSE);
    volume = NULL;
    if (unmount_error) goto out;
    if (fsync(image_fd)) goto out;
    close(image_fd);
    image_fd = -1;
    close(source);
    source = -1;
    stage = 6;
    if (verify(argv[1], &image_stat, argv[3], (uint64_t)source_stat.st_size,
               written_hash)) goto out;
    status = 0;
out:
    free(buffer);
    free(unicode_name);
    if (data) ntfs_attr_close(data);
    if (created) ntfs_inode_close(created);
    if (root) ntfs_inode_close(root);
    if (volume) ntfs_umount(volume, FALSE);
    if (image_fd >= 0) close(image_fd);
    if (source >= 0) close(source);
    sim_destroy();
    if (status) fprintf(stderr, "write or verification failed; stage=%d errno=%d; image needs inspection\n", stage, errno);
    else puts("PASS: image-only write, close, read-only reopen and SHA-256 verification");
    return status;
}
