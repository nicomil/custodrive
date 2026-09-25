#include "WriteEngine.h"
#include "OpenHDDNTFS.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

enum { COPY_CHUNK = 65536 };

typedef struct {
    int fd;
    uint64_t size;
    uint64_t position;
    int is_device;
    int io_failed;
    #ifdef OPENHDD_TESTING
    uint64_t read_calls;
    uint64_t write_calls;
    uint64_t sync_calls;
    #endif
} Target;

#ifdef OPENHDD_TESTING
static int fail_at(const char *name, uint64_t call)
{
    const char *value = getenv(name);
    if (!value || !*value) return 0;
    int saved_errno = errno;
    errno = 0;
    char *end = NULL;
    unsigned long long first = strtoull(value, &end, 10);
    int valid = !errno && end != value && !*end && first > 0;
    errno = saved_errno;
    return valid && call >= first;
}
#endif

static int durable_sync(Target *target)
{
    #ifdef OPENHDD_TESTING
    if (fail_at("OPENHDD_TEST_FAIL_SYNC_AT", ++target->sync_calls)) {
        target->io_failed = 1;
        errno = EIO;
        return -1;
    }
    #endif
    if (fsync(target->fd)) { target->io_failed = 1; return -1; }
    if (target->is_device && ioctl(target->fd, DKIOCSYNCHRONIZECACHE)) {
        target->io_failed = 1;
        return -1;
    }
    return 0;
}

static s64 bounded_io(Target *target, void *data, s64 count, s64 offset,
                      int writing)
{
    if (count < 0 || offset < 0 || count > SSIZE_MAX ||
        (uint64_t)offset > target->size ||
        (uint64_t)count > target->size - (uint64_t)offset) {
        target->io_failed = 1;
        errno = EINVAL;
        return -1;
    }
    size_t done = 0;
    while (done < (size_t)count) {
        #ifdef OPENHDD_TESTING
        if (!writing && fail_at("OPENHDD_TEST_FAIL_PREAD_AT",
                                ++target->read_calls)) {
            target->io_failed = 1;
            errno = EIO;
            return -1;
        }
        if (writing) {
            ++target->write_calls;
            int injected_error =
                fail_at("OPENHDD_TEST_FAIL_PWRITE_AT", target->write_calls) ? EIO :
                fail_at("OPENHDD_TEST_ENOSPC_PWRITE_AT", target->write_calls) ? ENOSPC : 0;
            if (injected_error) {
                target->io_failed = 1;
                errno = injected_error;
                return -1;
            }
        }
        #endif
        ssize_t n = writing ?
            pwrite(target->fd, (const char *)data + done,
                   (size_t)count - done, (off_t)offset + (off_t)done) :
            pread(target->fd, (char *)data + done,
                  (size_t)count - done, (off_t)offset + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) {
            if (n == 0) errno = EIO;
            target->io_failed = 1;
            return -1;
        }
        done += (size_t)n;
    }
    return count;
}

static Target *target_of(struct ntfs_device *device)
{
    return (Target *)device->d_private;
}

static int device_open(struct ntfs_device *device, int flags)
{
    if (NDevOpen(device) || (flags & O_ACCMODE) != O_RDWR) {
        errno = EBUSY;
        return -1;
    }
    if (target_of(device)->is_device) NDevSetBlock(device);
    NDevSetOpen(device);
    return 0;
}

static int device_close(struct ntfs_device *device)
{
    int result = durable_sync(target_of(device));
    NDevClearOpen(device);
    return result;
}

static s64 device_seek(struct ntfs_device *device, s64 offset, int whence)
{
    Target *target = target_of(device);
    uint64_t base = whence == SEEK_SET ? 0 :
        whence == SEEK_CUR ? target->position :
        whence == SEEK_END ? target->size : UINT64_MAX;
    if (base == UINT64_MAX || base > INT64_MAX ||
        (offset < 0 && (uint64_t)(-(offset + 1)) + 1 > base) ||
        (offset > 0 && (uint64_t)offset > target->size - base)) {
        errno = EINVAL;
        return -1;
    }
    uint64_t next = offset < 0 ? base - ((uint64_t)(-(offset + 1)) + 1) :
        base + (uint64_t)offset;
    if (next > target->size) { errno = EINVAL; return -1; }
    target->position = next;
    return (s64)next;
}

static s64 device_pread(struct ntfs_device *device, void *data,
                        s64 count, s64 offset)
{
    return bounded_io(target_of(device), data, count, offset, 0);
}

static s64 device_pwrite(struct ntfs_device *device, const void *data,
                         s64 count, s64 offset)
{
    return bounded_io(target_of(device), (void *)data, count, offset, 1);
}

static s64 device_read(struct ntfs_device *device, void *data, s64 count)
{
    Target *target = target_of(device);
    s64 result = device_pread(device, data, count, (s64)target->position);
    if (result > 0) target->position += (uint64_t)result;
    return result;
}

static s64 device_write(struct ntfs_device *device, const void *data, s64 count)
{
    Target *target = target_of(device);
    s64 result = device_pwrite(device, data, count, (s64)target->position);
    if (result > 0) target->position += (uint64_t)result;
    return result;
}

static int device_sync(struct ntfs_device *device)
{
    return durable_sync(target_of(device));
}

static int device_stat(struct ntfs_device *device, struct stat *out)
{
    Target *target = target_of(device);
    if (fstat(target->fd, out)) return -1;
    out->st_size = (off_t)target->size;
    return 0;
}

static int device_ioctl(struct ntfs_device *device, unsigned long request,
                        void *argument)
{
    return ioctl(target_of(device)->fd, request, argument);
}

static struct ntfs_device_operations operations = {
    .open = device_open, .close = device_close, .seek = device_seek,
    .read = device_read, .write = device_write, .pread = device_pread,
    .pwrite = device_pwrite, .sync = device_sync, .stat = device_stat,
    .ioctl = device_ioctl
};

static ntfs_volume *mount_rw(Target *target)
{
    struct ntfs_device *device = ntfs_device_alloc("OpenHDD exclusive fd",
                                                   0, &operations, target);
    if (!device) return NULL;
    /* Neither RECOVER nor IGNORE_HIBERFILE is permitted. */
    ntfs_volume *volume = ntfs_device_mount(device, 0);
    if (!volume) { ntfs_device_free(device); return NULL; }
    if (NVolReadOnly(volume) || (volume->flags & VOLUME_IS_DIRTY)) {
        ntfs_umount(volume, FALSE);
        errno = EBUSY;
        return NULL;
    }
    return volume;
}

static int64_t read_target(void *opaque, uint64_t offset,
                           void *buffer, uint64_t length)
{
    Target *target = opaque;
    if (length > INT64_MAX || offset > INT64_MAX) {
        errno = EOVERFLOW;
        return -1;
    }
    return bounded_io(target, buffer, (s64)length, (s64)offset, 0);
}

static int readonly_lookup(Target *target, const char *name,
                           OHNTFSItem *item, uint32_t *warning_bits)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = oh_ntfs_open(read_target, target, target->size,
                              &volume, &warnings);
    if (status) return status;
    *warning_bits = warnings;
    status = warnings ? EBUSY : oh_ntfs_lookup(volume, FILE_root, name, item);
    oh_ntfs_close(volume);
    return status;
}

static int check_unpublished_pending_entry(void *opaque, const char *name,
                                           const OHNTFSItem *item)
{
    (void)opaque;
    if (!strncmp(name, ".OpenHDD-pending-", 17) &&
        (item->kind != 1 || item->hard_link_count < 2)) return EINPROGRESS;
    return 0;
}

static int readonly_check_unpublished_pending(Target *target,
                                              uint64_t *free_bytes)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = oh_ntfs_open(read_target, target, target->size,
                              &volume, &warnings);
    if (status) return status;
    status = warnings ? EBUSY : oh_ntfs_list(volume, FILE_root,
                                            check_unpublished_pending_entry,
                                            NULL);
    if (!status) status = oh_ntfs_free_bytes(volume, free_bytes);
    oh_ntfs_close(volume);
    return status;
}

static int verify_file(Target *target, const char *name, uint64_t size,
                       const unsigned char digest[CC_SHA256_DIGEST_LENGTH],
                       uint64_t *inode)
{
    OHNTFSVolume *volume = NULL;
    OHNTFSItem item;
    uint32_t warnings = 0;
    unsigned char buffer[COPY_CHUNK], actual[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX context;
    int status = oh_ntfs_open(read_target, target, target->size,
                              &volume, &warnings);
    if (status) return status;
    if (warnings || oh_ntfs_lookup(volume, FILE_root, name, &item) ||
        item.kind != 1 || item.size != size || !CC_SHA256_Init(&context)) {
        status = EIO;
        goto out;
    }
    for (uint64_t offset = 0; offset < size; ) {
        uint64_t amount = size - offset;
        if (amount > sizeof(buffer)) amount = sizeof(buffer);
        if (oh_ntfs_read(volume, item.inode, offset, buffer, amount) !=
            (int64_t)amount ||
            !CC_SHA256_Update(&context, buffer, (CC_LONG)amount)) {
            status = EIO;
            goto out;
        }
        offset += amount;
    }
    if (!CC_SHA256_Final(actual, &context) ||
        memcmp(actual, digest, sizeof(actual))) status = EIO;
    else { *inode = item.inode; status = 0; }
out:
    oh_ntfs_close(volume);
    return status;
}

static int plain_name(const char *name)
{
    size_t length = strlen(name);
    if (!length || length > 120 || name[0] == '.' ||
        name[length - 1] == '.') return 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)name[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.'))
            return 0;
    }
    char base[16] = {0};
    size_t index = 0;
    while (name[index] && name[index] != '.' && index < sizeof(base) - 1) {
        unsigned char c = (unsigned char)name[index];
        base[index++] = c >= 'a' && c <= 'z' ? (char)(c - 32) : (char)c;
    }
    if (!strcmp(base, "CON") || !strcmp(base, "PRN") ||
        !strcmp(base, "AUX") || !strcmp(base, "NUL")) return 0;
    if (strlen(base) == 4 && (!memcmp(base, "COM", 3) ||
                              !memcmp(base, "LPT", 3)) &&
        base[3] >= '1' && base[3] <= '9') return 0;
    return 1;
}

static int create_pending(Target *target, int source_fd, const struct stat *source,
                          const char *pending,
                          unsigned char digest[CC_SHA256_DIGEST_LENGTH])
{
    ntfs_volume *volume = mount_rw(target);
    ntfs_inode *root = NULL, *created = NULL;
    ntfs_attr *data = NULL;
    ntfschar *wide = NULL;
    unsigned char buffer[COPY_CHUNK];
    CC_SHA256_CTX context;
    int result = -1;
    if (!volume) return -1;
    root = ntfs_inode_open(volume, FILE_root);
    if (!root) goto out;
    int count = ntfs_mbstoucs(pending, &wide);
    if (count <= 0 || count > 255) goto out;
    created = ntfs_create(root, const_cpu_to_le32(0), wide,
                          (u8)count, S_IFREG);
    if (!created) goto out;
    if (ntfs_inode_close(root)) { root = NULL; goto out; }
    root = NULL;
    data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
    if (!data) {
        if (errno != ENOENT ||
            ntfs_attr_add(created, AT_DATA, AT_UNNAMED, 0, NULL, 0))
            goto out;
        data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
        if (!data) goto out;
    }
    if (ntfs_attr_truncate_solid(data, source->st_size) ||
        !CC_SHA256_Init(&context)) goto out;
    for (uint64_t offset = 0; offset < (uint64_t)source->st_size; ) {
        #ifdef OPENHDD_TESTING
        if (offset && getenv("OPENHDD_TEST_FAIL_AFTER_FIRST_CHUNK")) {
            errno = EIO;
            goto out;
        }
        #endif
        size_t amount = (uint64_t)source->st_size - offset;
        if (amount > sizeof(buffer)) amount = sizeof(buffer);
        ssize_t got = read(source_fd, buffer, amount);
        if (got != (ssize_t)amount ||
            !CC_SHA256_Update(&context, buffer, (CC_LONG)amount))
            goto out;
        for (ssize_t done = 0; done < got; ) {
            s64 written = ntfs_attr_pwrite(data, (s64)(offset + done),
                                            got - done, buffer + done);
            if (written <= 0) goto out;
            done += written;
        }
        offset += amount;
        #ifdef OPENHDD_TESTING
        if (getenv("OPENHDD_TEST_ABORT_AFTER_FIRST_CHUNK"))
            _exit(86); /* Emulate a crash before close or sync. */
        #endif
    }
    struct stat after;
    if (fstat(source_fd, &after) || after.st_dev != source->st_dev ||
        after.st_ino != source->st_ino || after.st_size != source->st_size ||
        after.st_mtimespec.tv_sec != source->st_mtimespec.tv_sec ||
        after.st_mtimespec.tv_nsec != source->st_mtimespec.tv_nsec ||
        after.st_ctimespec.tv_sec != source->st_ctimespec.tv_sec ||
        after.st_ctimespec.tv_nsec != source->st_ctimespec.tv_nsec ||
        !CC_SHA256_Final(digest, &context)) goto out;
    ntfs_attr_close(data);
    data = NULL;
    if (ntfs_inode_close(created)) { created = NULL; goto out; }
    created = NULL;
    result = 0;
out:
    free(wide);
    if (data) ntfs_attr_close(data);
    if (created && ntfs_inode_close(created)) result = -1;
    if (root && ntfs_inode_close(root)) result = -1;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    return result;
}

static int publish(Target *target, const char *pending, const char *final_name,
                   uint64_t expected_inode)
{
    ntfs_volume *volume = mount_rw(target);
    ntfs_inode *root = NULL, *source = NULL;
    ntfschar *wide = NULL;
    int result = -1;
    if (!volume) return -1;
    root = ntfs_inode_open(volume, FILE_root);
    if (!root) goto out;
    source = ntfs_pathname_to_inode(volume, NULL, pending);
    if (!source || source->mft_no != expected_inode) goto out;
    ntfs_inode *existing = ntfs_pathname_to_inode(volume, NULL, final_name);
    if (existing) {
        ntfs_inode_close(existing);
        errno = EEXIST;
        goto out;
    }
    if (errno != ENOENT) goto out;
    int count = ntfs_mbstoucs(final_name, &wide);
    if (count <= 0 || count > 255 || ntfs_link(source, root, wide, (u8)count))
        goto out;
    #ifdef OPENHDD_TESTING
    if (getenv("OPENHDD_TEST_FAIL_AFTER_LINK")) {
        errno = EIO;
        goto out;
    }
    #endif
    result = 0;
out:
    free(wide);
    if (source && ntfs_inode_close(source)) result = -1;
    if (root && ntfs_inode_close(root)) result = -1;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    return result;
}

int oh_copy_new_file(int target_fd, uint64_t target_size, int is_device,
                     int source_fd, const char *destination_name,
                     int *failure_stage)
{
    if (!failure_stage || !destination_name || !plain_name(destination_name) ||
        target_size < 4096 || target_size > INT64_MAX) return EINVAL;
    *failure_stage = 1;
    ntfs_log_set_handler(ntfs_log_handler_null);
    struct stat source;
    if (fstat(source_fd, &source) || !S_ISREG(source.st_mode) ||
        source.st_size < 0 || source.st_size > INT64_MAX / 2 ||
        lseek(source_fd, 0, SEEK_SET) != 0) return EINVAL;
    Target target = { .fd = target_fd, .size = target_size,
                      .position = 0, .is_device = is_device };
    OHNTFSItem item;
    uint32_t warnings = 0;
    int status = readonly_lookup(&target, destination_name, &item, &warnings);
    if (target.io_failed) return EIO;
    if (status != ENOENT) return status ? status : EEXIST;
    uint64_t free_bytes = 0;
    status = readonly_check_unpublished_pending(&target, &free_bytes);
    if (target.io_failed) return EIO;
    if (status) return status;
    uint64_t reserve = (uint64_t)source.st_size / 100;
    if (reserve < 16 * 1024 * 1024) reserve = 16 * 1024 * 1024;
    if (free_bytes < (uint64_t)source.st_size + reserve) return ENOSPC;
    char pending[64];
    unsigned char random_bytes[16];
    arc4random_buf(random_bytes, sizeof(random_bytes));
    static const char hex[] = "0123456789abcdef";
    memcpy(pending, ".OpenHDD-pending-", 17);
    for (size_t i = 0; i < sizeof(random_bytes); ++i) {
        pending[17 + i * 2] = hex[random_bytes[i] >> 4];
        pending[18 + i * 2] = hex[random_bytes[i] & 15];
    }
    pending[49] = 0;
    status = readonly_lookup(&target, pending, &item, &warnings);
    if (target.io_failed) return EIO;
    if (status != ENOENT) return status ? status : EEXIST;
    *failure_stage = 2;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (create_pending(&target, source_fd, &source, pending, digest))
        return target.io_failed ? EIO : (errno ? errno : EIO);
    if (target.io_failed) return EIO;
    *failure_stage = 3;
    uint64_t pending_inode = 0, final_inode = 0;
    status = verify_file(&target, pending, (uint64_t)source.st_size,
                         digest, &pending_inode);
    if (status || target.io_failed) return status ? status : EIO;
    *failure_stage = 4;
    #ifdef OPENHDD_TESTING
    if (getenv("OPENHDD_TEST_FAIL_BEFORE_PUBLISH")) return EIO;
    #endif
    if (publish(&target, pending, destination_name, pending_inode))
        return target.io_failed ? EIO : (errno ? errno : EIO);
    if (target.io_failed) return EIO;
    *failure_stage = 5;
    status = verify_file(&target, destination_name, (uint64_t)source.st_size,
                         digest, &final_inode);
    if (status || final_inode != pending_inode || target.io_failed)
        return status ? status : EIO;
    *failure_stage = 0;
    return 0;
}
