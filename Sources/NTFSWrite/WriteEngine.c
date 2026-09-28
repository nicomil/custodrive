#include "WriteEngine.h"
#include "OpenHDDNTFS.h"

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
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

enum { COPY_CHUNK = 65536, MAX_ITEMS = 4096, PENDING_LENGTH = 49 };

static const char pending_prefix[] = ".OpenHDD-pending-";

typedef struct {
    int fd;
    uint64_t size;
    uint64_t position;
    int is_device;
    int io_failed;
    /* Set once this session has written VOLUME_IS_DIRTY itself. Only then
       may the engine mount or verify a dirty volume. */
    int own_dirty;
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

static int short_at(const char *name, uint64_t call)
{
    return fail_at(name, call) && !fail_at(name, call - 1);
}

static void abort_at_stage(int stage)
{
    const char *requested = getenv("OPENHDD_TEST_ABORT_AT_STAGE");
    if (requested && requested[0] == '0' + stage && !requested[1])
        _exit(86);
}

/* Power-cut model for tests. With OPENHDD_TEST_POWERCUT_AT_WRITE=N every
   write is held in a volatile cache until the next sync, like a drive with a
   write-back cache. At write N a seeded random subset of the cached writes
   reaches the image, some cut at a 512-byte boundary, and the process dies.
   Syncs are the only ordering barriers the engine may rely on. */
typedef struct CachedWrite {
    struct CachedWrite *next;
    uint64_t offset;
    size_t length;
    unsigned char data[];
} CachedWrite;

static CachedWrite *cache_head, *cache_tail;
static uint64_t cache_bytes;

static uint64_t env_number(const char *name)
{
    const char *value = getenv(name);
    return value && *value ? strtoull(value, NULL, 10) : 0;
}

static int cache_enabled(void)
{
    return env_number("OPENHDD_TEST_POWERCUT_AT_WRITE") > 0;
}

static uint64_t cut_random(void)
{
    static uint64_t state;
    if (!state) state = env_number("OPENHDD_TEST_POWERCUT_SEED") * 2654435761ULL + 1;
    state ^= state << 13; state ^= state >> 7; state ^= state << 17;
    return state;
}

/* Writes tear only at physical-sector boundaries of the device:
   OPENHDD_TEST_POWERCUT_SECTOR (512 by default; 4096 for 4K-native media). */
static void power_cut(int fd)
{
    uint64_t sector = env_number("OPENHDD_TEST_POWERCUT_SECTOR");
    if (sector < 512 || (sector & (sector - 1))) sector = 512;
    for (CachedWrite *w = cache_head; w; w = w->next) {
        uint64_t roll = cut_random() % 4;
        if (roll == 0) continue;                 /* lost */
        size_t length = w->length;
        if (roll == 1) {                         /* torn */
            uint64_t end = w->offset + w->length;
            uint64_t first = (w->offset / sector + 1) * sector;
            if (first < end) {
                uint64_t choices = (end - first + sector - 1) / sector;
                uint64_t cut_at = first + (cut_random() % choices) * sector;
                length = (size_t)(cut_at - w->offset);
            }
        }
        if (length) (void)!pwrite(fd, w->data, length, (off_t)w->offset);
    }
    fsync(fd);
    _exit(86);
}

static int cache_write(Target *target, const void *data, size_t length,
                       uint64_t offset)
{
    if (target->write_calls >= env_number("OPENHDD_TEST_POWERCUT_AT_WRITE"))
        power_cut(target->fd);
    CachedWrite *w = malloc(sizeof(*w) + length);
    if (!w || cache_bytes + length > 512ULL * 1024 * 1024) {
        free(w);
        errno = ENOMEM;
        return -1;
    }
    w->next = NULL;
    w->offset = offset;
    w->length = length;
    memcpy(w->data, data, length);
    if (cache_tail) cache_tail->next = w; else cache_head = w;
    cache_tail = w;
    cache_bytes += length;
    return 0;
}

static void cache_overlay(void *data, size_t length, uint64_t offset)
{
    for (CachedWrite *w = cache_head; w; w = w->next) {
        uint64_t start = w->offset > offset ? w->offset : offset;
        uint64_t end = w->offset + w->length < offset + length ?
            w->offset + w->length : offset + length;
        if (start < end)
            memcpy((char *)data + (start - offset), w->data + (start - w->offset),
                   (size_t)(end - start));
    }
}

static int cache_flush(int fd)
{
    while (cache_head) {
        CachedWrite *w = cache_head;
        if (pwrite(fd, w->data, w->length, (off_t)w->offset) != (ssize_t)w->length)
            return -1;
        cache_head = w->next;
        cache_bytes -= w->length;
        free(w);
    }
    cache_tail = NULL;
    return 0;
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
    if (cache_enabled() && cache_flush(target->fd)) {
        target->io_failed = 1;
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
        size_t request = (size_t)count - done;
        #ifdef OPENHDD_TESTING
        if (request > 1 && short_at(writing ? "OPENHDD_TEST_SHORT_PWRITE_AT" :
                                   "OPENHDD_TEST_SHORT_PREAD_AT",
                                   writing ? target->write_calls : target->read_calls))
            request /= 2;
        #endif
        #ifdef OPENHDD_TESTING
        if (cache_enabled()) {
            if (writing) {
                if (cache_write(target, (const char *)data + done, request,
                                (uint64_t)offset + done)) {
                    target->io_failed = 1;
                    return -1;
                }
                done += request;
                continue;
            }
            ssize_t got = pread(target->fd, (char *)data + done, request,
                                (off_t)offset + (off_t)done);
            if (got > 0) cache_overlay((char *)data + done, (size_t)got,
                                       (uint64_t)offset + done);
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) {
                if (got == 0) errno = EIO;
                target->io_failed = 1;
                return -1;
            }
            done += (size_t)got;
            continue;
        }
        #endif
        ssize_t n = writing ?
            pwrite(target->fd, (const char *)data + done,
                   request, (off_t)offset + (off_t)done) :
            pread(target->fd, (char *)data + done,
                  request, (off_t)offset + (off_t)done);
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
    if (NVolReadOnly(volume) ||
        ((volume->flags & VOLUME_IS_DIRTY) && !target->own_dirty)) {
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

/* Read-only view. The dirty warning is hidden only while this session owns
   the dirty mark; every other warning still blocks. */
static int readonly_open(Target *target, OHNTFSVolume **volume,
                         uint32_t *warnings)
{
    uint32_t found = 0;
    int status = oh_ntfs_open(read_target, target, target->size,
                              volume, &found);
    if (!status && target->own_dirty) found &= ~(uint32_t)OH_NTFS_WARNING_DIRTY;
    *warnings = found;
    return status;
}

static int check_pending_entry(void *opaque, const char *name,
                               const OHNTFSItem *item)
{
    (void)opaque; (void)item;
    if (!strncmp(name, pending_prefix, sizeof(pending_prefix) - 1))
        return EINPROGRESS;
    return 0;
}

/* A leftover temporary name is reported before any other warning, so an
   interrupted OpenHDD session is recognised as such even though it also
   left the volume dirty. */
static int volume_scan(Target *target, uint64_t *free_bytes,
                       uint32_t *warnings)
{
    OHNTFSVolume *volume = NULL;
    int status = readonly_open(target, &volume, warnings);
    if (status) return target->io_failed ? EIO : status;
    status = oh_ntfs_list(volume, FILE_root, check_pending_entry, NULL);
    if (!status && *warnings) status = EBUSY;
    if (!status && free_bytes) status = oh_ntfs_free_bytes(volume, free_bytes);
    oh_ntfs_close(volume);
    return target->io_failed ? EIO : status;
}

int oh_ntfs_safety_preflight(int target_fd, uint64_t target_size,
                             uint64_t *free_bytes, uint32_t *warnings)
{
    if (target_fd < 0 || target_size < 4096 || target_size > INT64_MAX ||
        !free_bytes || !warnings) return EINVAL;
    Target target = { .fd = target_fd, .size = target_size };
    *free_bytes = 0;
    *warnings = 0;
    ntfs_log_set_handler(ntfs_log_handler_null);
    return volume_scan(&target, free_bytes, warnings);
}

static int resolve_directory(Target *target, const char *path, uint64_t *inode)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    status = warnings ? EBUSY : oh_ntfs_resolve_directory(volume, path, inode);
    oh_ntfs_close(volume);
    return target->io_failed ? EIO : status;
}

static int name_is_free(Target *target, uint64_t directory, const char *name)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int exists = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    status = warnings ? EBUSY :
        oh_ntfs_name_exists_nocase(volume, directory, name, &exists);
    oh_ntfs_close(volume);
    if (target->io_failed) return EIO;
    return status ? status : exists ? EEXIST : 0;
}

static int verify_file(Target *target, uint64_t directory, const char *name,
                       uint64_t size,
                       const unsigned char digest[CC_SHA256_DIGEST_LENGTH],
                       uint64_t *inode)
{
    OHNTFSVolume *volume = NULL;
    OHNTFSItem item;
    uint32_t warnings = 0;
    unsigned char buffer[COPY_CHUNK], actual[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_CTX context;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    if (warnings || oh_ntfs_lookup(volume, directory, name, &item) ||
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
    if (!size) {
        unsigned char probe;
        if (oh_ntfs_read(volume, item.inode, 0, &probe, 1) != 0) {
            status = EIO;
            goto out;
        }
    }
    if (!CC_SHA256_Final(actual, &context) ||
        memcmp(actual, digest, sizeof(actual))) status = EIO;
    else { *inode = item.inode; status = 0; }
out:
    oh_ntfs_close(volume);
    return status;
}

/* ------------------------------------------------------------------------ */
/* Names                                                                    */
/* ------------------------------------------------------------------------ */

/* Decodes one UTF-8 scalar value; returns bytes consumed or 0 if invalid. */
static size_t utf8_next(const unsigned char *s, uint32_t *out)
{
    if (s[0] < 0x80) { *out = s[0]; return 1; }
    if (s[0] >= 0xC2 && s[0] <= 0xDF && (s[1] & 0xC0) == 0x80) {
        *out = ((uint32_t)(s[0] & 0x1F) << 6) | (s[1] & 0x3F);
        return 2;
    }
    if (s[0] >= 0xE0 && s[0] <= 0xEF && (s[1] & 0xC0) == 0x80 &&
        (s[2] & 0xC0) == 0x80) {
        uint32_t c = ((uint32_t)(s[0] & 0x0F) << 12) |
            ((uint32_t)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
        if (c < 0x800 || (c >= 0xD800 && c <= 0xDFFF)) return 0;
        *out = c;
        return 3;
    }
    if (s[0] >= 0xF0 && s[0] <= 0xF4 && (s[1] & 0xC0) == 0x80 &&
        (s[2] & 0xC0) == 0x80 && (s[3] & 0xC0) == 0x80) {
        uint32_t c = ((uint32_t)(s[0] & 0x07) << 18) |
            ((uint32_t)(s[1] & 0x3F) << 12) |
            ((uint32_t)(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
        if (c < 0x10000 || c > 0x10FFFF) return 0;
        *out = c;
        return 4;
    }
    return 0;
}

static int is_nfc(const char *name)
{
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, name,
                                                   kCFStringEncodingUTF8);
    if (!string) return 0;
    CFMutableStringRef normal = CFStringCreateMutableCopy(kCFAllocatorDefault,
                                                          0, string);
    int same = 0;
    if (normal) {
        CFStringNormalize(normal, kCFStringNormalizationFormC);
        same = CFStringCompare(string, normal, 0) == kCFCompareEqualTo;
        CFRelease(normal);
    }
    CFRelease(string);
    return same;
}

static int reserved_device_name(const char *name)
{
    char base[8] = {0};
    size_t length = 0;
    while (name[length] && name[length] != '.' && length < 6) ++length;
    if (name[length] && name[length] != '.') return 0;
    while (length && name[length - 1] == ' ') --length;
    if (length < 3 || length > 4) return 0;
    for (size_t i = 0; i < length; ++i) {
        unsigned char c = (unsigned char)name[i];
        base[i] = c >= 'a' && c <= 'z' ? (char)(c - 32) : (char)c;
    }
    if (length == 3)
        return !strcmp(base, "CON") || !strcmp(base, "PRN") ||
            !strcmp(base, "AUX") || !strcmp(base, "NUL");
    return (!memcmp(base, "COM", 3) || !memcmp(base, "LPT", 3)) &&
        base[3] >= '1' && base[3] <= '9';
}

/* A new file name that Windows Explorer can show, open and delete. */
int oh_ntfs_valid_new_name(const char *name)
{
    if (!name) return 0;
    size_t length = strlen(name);
    if (!length || length > 1020) return 0;
    if (!strncmp(name, ".OpenHDD-", 9)) return 0;
    if (!strcmp(name, ".") || !strcmp(name, "..")) return 0;
    if (name[length - 1] == '.' || name[length - 1] == ' ') return 0;
    size_t units = 0;
    for (size_t i = 0; i < length; ) {
        uint32_t c = 0;
        size_t used = utf8_next((const unsigned char *)name + i, &c);
        if (!used) return 0;
        if (c < 0x20 || c == 0x7F ||
            (c < 0x80 && strchr("\"*/:<>?\\|", (int)c))) return 0;
        units += c >= 0x10000 ? 2 : 1;
        i += used;
    }
    if (units > 255) return 0;
    if (reserved_device_name(name)) return 0;
    return is_nfc(name);
}

/* An existing destination directory, relative to the volume root. */
int oh_ntfs_valid_directory_path(const char *path)
{
    if (!path) return 1;
    size_t length = strlen(path);
    if (length > 1024) return 0;
    const unsigned char *s = (const unsigned char *)path;
    size_t component = 0;
    for (size_t i = 0; i <= length; ) {
        if (i == length || s[i] == '/') {
            if (component == 1 && s[i - 1] == '.') return 0;
            if (component == 2 && s[i - 1] == '.' && s[i - 2] == '.') return 0;
            component = 0;
            ++i;
            continue;
        }
        uint32_t c = 0;
        size_t used = utf8_next(s + i, &c);
        if (!used || c < 0x20 || c == 0x7F || c == '\\') return 0;
        component += used;
        if (component > 1020) return 0;
        i += used;
    }
    return is_nfc(path);
}

static int same_name_ignoring_case(const char *a, const char *b)
{
    CFStringRef left = CFStringCreateWithCString(kCFAllocatorDefault, a,
                                                 kCFStringEncodingUTF8);
    CFStringRef right = CFStringCreateWithCString(kCFAllocatorDefault, b,
                                                  kCFStringEncodingUTF8);
    int same = 1; /* fail closed if either string cannot be built */
    if (left && right)
        same = CFStringCompare(left, right, kCFCompareCaseInsensitive) ==
            kCFCompareEqualTo;
    if (left) CFRelease(left);
    if (right) CFRelease(right);
    return same;
}

/* ------------------------------------------------------------------------ */
/* Read-write phases                                                        */
/* ------------------------------------------------------------------------ */

/* Flips only VOLUME_IS_DIRTY. Unknown bits written by newer Windows versions
   are preserved (ntfs_volume_write_flags would mask them away). */
static int write_dirty_flag(ntfs_volume *volume, int dirty)
{
    ntfs_attr_search_ctx *ctx = ntfs_attr_get_search_ctx(volume->vol_ni, NULL);
    if (!ctx) return -1;
    int result = -1;
    if (ntfs_attr_lookup(AT_VOLUME_INFORMATION, AT_UNNAMED, 0, 0, 0, NULL,
                         0, ctx)) goto out;
    ATTR_RECORD *attribute = ctx->attr;
    uint32_t value_length = le32_to_cpu(attribute->value_length);
    uint16_t value_offset = le16_to_cpu(attribute->value_offset);
    if (attribute->non_resident || value_length < sizeof(VOLUME_INFORMATION) ||
        (uint32_t)value_offset + value_length > le32_to_cpu(attribute->length)) {
        errno = EIO;
        goto out;
    }
    VOLUME_INFORMATION *info =
        (VOLUME_INFORMATION *)((char *)attribute + value_offset);
    uint16_t flags = le16_to_cpu(info->flags);
    flags = dirty ? (uint16_t)(flags | le16_to_cpu(VOLUME_IS_DIRTY)) :
        (uint16_t)(flags & ~le16_to_cpu(VOLUME_IS_DIRTY));
    info->flags = cpu_to_le16(flags);
    volume->flags = info->flags;
    ntfs_inode_mark_dirty(volume->vol_ni);
    if (ntfs_inode_sync(volume->vol_ni)) goto out;
    result = 0;
out:
    ntfs_attr_put_search_ctx(ctx);
    return result;
}

/* The dirty mark is the safety net for an interrupted session: it is made
   durable before any other change and cleared only after every file has been
   published and verified. Each transition is confirmed by a fresh read. */
static int set_volume_dirty(Target *target, int dirty)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = write_dirty_flag(volume, dirty);
    int saved = errno;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (result) { errno = saved ? saved : EIO; return -1; }

    OHNTFSVolume *check = NULL;
    uint32_t warnings = 0;
    int status = oh_ntfs_open(read_target, target, target->size,
                              &check, &warnings);
    if (status) { errno = status; return -1; }
    oh_ntfs_close(check);
    int is_dirty = (warnings & OH_NTFS_WARNING_DIRTY) != 0;
    uint32_t others = warnings & ~(uint32_t)OH_NTFS_WARNING_DIRTY;
    if (target->io_failed || is_dirty != (dirty != 0) || others) {
        errno = EIO;
        return -1;
    }
    target->own_dirty = dirty;
    return 0;
}

static int create_pending(Target *target, int source_fd,
                          const struct stat *source, const char *pending,
                          size_t index, OHCopyProgress progress, void *context,
                          unsigned char digest[CC_SHA256_DIGEST_LENGTH])
{
    ntfs_volume *volume = mount_rw(target);
    ntfs_inode *root = NULL, *created = NULL;
    ntfs_attr *data = NULL;
    ntfschar *wide = NULL;
    unsigned char buffer[COPY_CHUNK];
    CC_SHA256_CTX sha;
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
        !CC_SHA256_Init(&sha)) goto out;
    if (lseek(source_fd, 0, SEEK_SET) != 0) goto out;
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
            !CC_SHA256_Update(&sha, buffer, (CC_LONG)amount))
            goto out;
        for (ssize_t done = 0; done < got; ) {
            s64 written = ntfs_attr_pwrite(data, (s64)(offset + done),
                                            got - done, buffer + done);
            if (written <= 0) goto out;
            done += written;
        }
        offset += amount;
        if (progress) progress(context, index, offset, (uint64_t)source->st_size);
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
        !CC_SHA256_Final(digest, &sha)) goto out;
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

static ntfs_inode *open_directory(ntfs_volume *volume, const char *path)
{
    if (!path || !*path) return ntfs_inode_open(volume, FILE_root);
    ntfs_inode *directory = ntfs_pathname_to_inode(volume, NULL, path);
    if (directory && !(directory->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
        ntfs_inode_close(directory);
        errno = ENOTDIR;
        return NULL;
    }
    return directory;
}

static int publish(Target *target, const char *pending,
                   const char *directory_path, const char *final_name,
                   uint64_t expected_inode)
{
    ntfs_volume *volume = mount_rw(target);
    ntfs_inode *directory = NULL, *source = NULL;
    ntfschar *wide = NULL;
    int result = -1;
    if (!volume) return -1;
    directory = open_directory(volume, directory_path);
    if (!directory) goto out;
    source = ntfs_pathname_to_inode(volume, NULL, pending);
    if (!source || source->mft_no != expected_inode) goto out;
    ntfs_inode *existing = ntfs_pathname_to_inode(volume, directory, final_name);
    if (existing) {
        ntfs_inode_close(existing);
        errno = EEXIST;
        goto out;
    }
    if (errno != ENOENT) goto out;
    int count = ntfs_mbstoucs(final_name, &wide);
    if (count <= 0 || count > 255 ||
        ntfs_link(source, directory, wide, (u8)count))
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
    if (directory && ntfs_inode_close(directory)) result = -1;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    return result;
}

/* Remove only the temporary name after the final name has been verified.
   Any failure before this point leaves a pending entry that blocks new writes. */
static int complete_pending(Target *target, const char *pending,
                            const char *directory_path, const char *final_name,
                            uint64_t expected_inode)
{
    ntfs_volume *volume = mount_rw(target);
    ntfs_inode *root = NULL, *directory = NULL, *temporary = NULL, *final = NULL;
    ntfschar *wide = NULL;
    int result = -1;
    if (!volume) return -1;
    root = ntfs_inode_open(volume, FILE_root);
    directory = open_directory(volume, directory_path);
    if (!root || !directory) goto out;
    temporary = ntfs_pathname_to_inode(volume, NULL, pending);
    final = ntfs_pathname_to_inode(volume, directory, final_name);
    if (!temporary || !final || temporary->mft_no != expected_inode ||
        final->mft_no != expected_inode ||
        le16_to_cpu(temporary->mrec->link_count) != 2) {
        errno = EIO;
        goto out;
    }
    if (ntfs_inode_close(final)) { final = NULL; goto out; }
    final = NULL;
    if (ntfs_inode_close(directory)) { directory = NULL; goto out; }
    directory = NULL;
    int count = ntfs_mbstoucs(pending, &wide);
    if (count <= 0 || count > 255) goto out;
    ntfs_inode *entry = temporary;
    ntfs_inode *parent = root;
    temporary = NULL;
    root = NULL;
    if (ntfs_delete(volume, pending, entry, parent, wide, (u8)count))
        goto out;
    result = 0;
out:
    free(wide);
    if (final && ntfs_inode_close(final)) result = -1;
    if (temporary && ntfs_inode_close(temporary)) result = -1;
    if (directory && ntfs_inode_close(directory)) result = -1;
    if (root && ntfs_inode_close(root)) result = -1;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    return result;
}

static int phase_error(Target *target)
{
    return target->io_failed ? EIO : (errno ? errno : EIO);
}

static void make_pending_name(char pending[PENDING_LENGTH + 1])
{
    unsigned char random_bytes[16];
    static const char hex[] = "0123456789abcdef";
    arc4random_buf(random_bytes, sizeof(random_bytes));
    memcpy(pending, pending_prefix, sizeof(pending_prefix) - 1);
    for (size_t i = 0; i < sizeof(random_bytes); ++i) {
        pending[17 + i * 2] = hex[random_bytes[i] >> 4];
        pending[18 + i * 2] = hex[random_bytes[i] & 15];
    }
    pending[PENDING_LENGTH] = 0;
}

typedef struct {
    char names[64][PENDING_LENGTH + 1];
    size_t count;
} PendingList;

static int collect_pending(void *opaque, const char *name,
                           const OHNTFSItem *item)
{
    PendingList *list = opaque;
    if (strncmp(name, pending_prefix, sizeof(pending_prefix) - 1)) return 0;
    if (item->kind != 1 || strlen(name) != PENDING_LENGTH ||
        list->count == sizeof(list->names) / sizeof(list->names[0]))
        return EPERM;
    memcpy(list->names[list->count++], name, PENDING_LENGTH + 1);
    return 0;
}

/* Temporary names left by an interrupted session, on a volume that is no
   longer dirty (Windows has checked it). Only OpenHDD's own temporaries are
   removed: either unpublished partial files or the second name of a file
   that was already published. The removal is itself a marked session. */
static int remove_pending(Target *target, size_t *removed)
{
    PendingList list = { .count = 0 };
    OHNTFSVolume *view = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &view, &warnings);
    if (status) return status;
    status = warnings ? EBUSY : oh_ntfs_list(view, FILE_root, collect_pending, &list);
    oh_ntfs_close(view);
    if (status || target->io_failed) return target->io_failed ? EIO : status;
    if (!list.count) return 0;
    if (set_volume_dirty(target, 1)) return phase_error(target);
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return phase_error(target);
    int result = 0;
    for (size_t i = 0; i < list.count && !result; ++i) {
        ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
        ntfs_inode *entry = ntfs_pathname_to_inode(volume, NULL, list.names[i]);
        ntfschar *wide = NULL;
        int count = ntfs_mbstoucs(list.names[i], &wide);
        if (!root || !entry || count <= 0 ||
            (entry->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
            if (entry) ntfs_inode_close(entry);
            if (root) ntfs_inode_close(root);
            result = -1;
        } else if (ntfs_delete(volume, list.names[i], entry, root, wide, (u8)count)) {
            result = -1; /* ntfs_delete closes both inodes */
        }
        free(wide);
    }
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (result) return phase_error(target);
    if (set_volume_dirty(target, 0)) return phase_error(target);
    *removed = list.count;
    return 0;
}

static int copy_one(Target *target, const char *directory_path,
                    uint64_t directory_inode, const OHCopyItem *item,
                    const struct stat *source, size_t index,
                    OHCopyProgress progress, void *context, int *stage)
{
    char pending[PENDING_LENGTH + 1];
    OHNTFSItem found;
    uint32_t warnings = 0;
    make_pending_name(pending);
    OHNTFSVolume *volume = NULL;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    status = warnings ? EBUSY : oh_ntfs_lookup(volume, FILE_root, pending, &found);
    oh_ntfs_close(volume);
    if (target->io_failed) return EIO;
    if (status != ENOENT) return status ? status : EEXIST;

    *stage = 2;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    if (create_pending(target, item->source_fd, source, pending, index,
                       progress, context, digest))
        return phase_error(target);
    if (target->io_failed) return EIO;

    *stage = 3;
    #ifdef OPENHDD_TESTING
    abort_at_stage(3);
    #endif
    uint64_t pending_inode = 0, final_inode = 0;
    status = verify_file(target, FILE_root, pending, (uint64_t)source->st_size,
                         digest, &pending_inode);
    if (status || target->io_failed) return status ? status : EIO;
    status = name_is_free(target, directory_inode, item->destination_name);
    if (status) return status;

    *stage = 4;
    #ifdef OPENHDD_TESTING
    abort_at_stage(4);
    if (getenv("OPENHDD_TEST_FAIL_BEFORE_PUBLISH")) return EIO;
    #endif
    if (publish(target, pending, directory_path, item->destination_name,
                pending_inode))
        return phase_error(target);
    if (target->io_failed) return EIO;

    *stage = 5;
    #ifdef OPENHDD_TESTING
    abort_at_stage(5);
    #endif
    status = verify_file(target, directory_inode, item->destination_name,
                         (uint64_t)source->st_size, digest, &final_inode);
    if (status || final_inode != pending_inode || target->io_failed)
        return status ? status : EIO;
    if (complete_pending(target, pending, directory_path,
                         item->destination_name, final_inode))
        return phase_error(target);
    if (target->io_failed) return EIO;
    status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    status = warnings ? EBUSY : oh_ntfs_lookup(volume, FILE_root, pending, &found);
    oh_ntfs_close(volume);
    if (status != ENOENT || target->io_failed)
        return target->io_failed ? EIO : (status ? status : EIO);
    status = verify_file(target, directory_inode, item->destination_name,
                         (uint64_t)source->st_size, digest, &final_inode);
    if (status || final_inode != pending_inode || target->io_failed)
        return status ? status : EIO;
    return 0;
}

int oh_copy_new_files(int target_fd, uint64_t target_size, int is_device,
                      const char *directory_path,
                      const OHCopyItem *items, size_t count,
                      OHCopyProgress progress, void *progress_context,
                      size_t *failed_index, int *failure_stage,
                      uint32_t *safety_warnings, size_t *removed_pending)
{
    if (!failure_stage || !safety_warnings || !failed_index) return EINVAL;
    *failure_stage = 1;
    *failed_index = 0;
    *safety_warnings = 0;
    if (removed_pending) *removed_pending = 0;
    if (!items || !count || count > MAX_ITEMS) return EINVAL;
    struct stat target_info;
    if (fstat(target_fd, &target_info)) return EINVAL;
    if (is_device ? !(S_ISBLK(target_info.st_mode) || S_ISCHR(target_info.st_mode)) :
        !S_ISREG(target_info.st_mode)) return EPERM;
    if (target_size < 4096 || target_size > INT64_MAX) return EINVAL;
    if (directory_path && (!*directory_path || !strcmp(directory_path, "/")))
        directory_path = NULL;
    if (!oh_ntfs_valid_directory_path(directory_path)) return EINVAL;
    ntfs_log_set_handler(ntfs_log_handler_null);

    struct stat *sources = calloc(count, sizeof(*sources));
    if (!sources) return ENOMEM;
    int status = 0;
    uint64_t total = 0;
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        if (!oh_ntfs_valid_new_name(items[i].destination_name)) status = EINVAL;
        for (size_t j = 0; j < i && !status; ++j)
            if (same_name_ignoring_case(items[i].destination_name,
                                        items[j].destination_name))
                status = EEXIST;
        if (!status && (fstat(items[i].source_fd, &sources[i]) ||
            !S_ISREG(sources[i].st_mode) || sources[i].st_size < 0 ||
            sources[i].st_size > INT64_MAX / 2 ||
            (sources[i].st_dev == target_info.st_dev &&
             sources[i].st_ino == target_info.st_ino) ||
            lseek(items[i].source_fd, 0, SEEK_SET) != 0))
            status = EINVAL;
        if (!status && total > (uint64_t)INT64_MAX - (uint64_t)sources[i].st_size)
            status = EFBIG;
        if (!status) total += (uint64_t)sources[i].st_size;
    }
    if (status) goto out;

    Target target = { .fd = target_fd, .size = target_size,
                      .is_device = is_device };
    uint64_t free_bytes = 0, directory_inode = FILE_root;
    *failed_index = 0;
    status = volume_scan(&target, &free_bytes, safety_warnings);
    if (status == EINPROGRESS && !*safety_warnings && removed_pending) {
        size_t removed = 0;
        *failure_stage = 2;
        status = remove_pending(&target, &removed);
        if (status) goto out;
        *removed_pending = removed;
        *failure_stage = 1;
        status = volume_scan(&target, &free_bytes, safety_warnings);
    }
    if (status) goto out;
    if (directory_path) {
        status = resolve_directory(&target, directory_path, &directory_inode);
        if (status) goto out;
    }
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        status = name_is_free(&target, directory_inode,
                              items[i].destination_name);
    }
    if (status) goto out;
    *failed_index = 0;
    uint64_t reserve = total / 100;
    if (reserve < 16 * 1024 * 1024) reserve = 16 * 1024 * 1024;
    /* Per-file metadata overhead: MFT record and index growth. */
    reserve += (uint64_t)count * 64 * 1024;
    if (free_bytes < total || free_bytes - total < reserve) {
        status = ENOSPC;
        goto out;
    }

    #ifdef OPENHDD_TESTING
    abort_at_stage(2);
    #endif
    *failure_stage = 2;
    if (set_volume_dirty(&target, 1)) { status = phase_error(&target); goto out; }

    for (size_t i = 0; i < count; ++i) {
        *failed_index = i;
        status = copy_one(&target, directory_path, directory_inode, &items[i],
                          &sources[i], i, progress, progress_context,
                          failure_stage);
        if (status) goto out;
        if (progress) progress(progress_context, i, (uint64_t)sources[i].st_size,
                               (uint64_t)sources[i].st_size);
    }

    *failure_stage = 6;
    #ifdef OPENHDD_TESTING
    abort_at_stage(6);
    #endif
    if (set_volume_dirty(&target, 0)) { status = phase_error(&target); goto out; }
    uint32_t final_warnings = 0;
    status = volume_scan(&target, NULL, &final_warnings);
    if (status || final_warnings) { status = status ? status : EIO; goto out; }
    *failure_stage = 0;
    #ifdef OPENHDD_TESTING
    abort_at_stage(0);
    if (getenv("OPENHDD_TEST_REPORT_WRITES"))
        fprintf(stderr, "writes=%llu\n", (unsigned long long)target.write_calls);
    #endif
out:
    free(sources);
    return status;
}

int oh_copy_new_file(int target_fd, uint64_t target_size, int is_device,
                     int source_fd, const char *destination_name,
                     int *failure_stage, uint32_t *safety_warnings)
{
    OHCopyItem item = { .source_fd = source_fd,
                        .destination_name = destination_name };
    size_t failed = 0;
    return oh_copy_new_files(target_fd, target_size, is_device, NULL, &item, 1,
                             NULL, NULL, &failed, failure_stage,
                             safety_warnings, NULL);
}
