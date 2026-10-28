#include "WriteEngine.h"
#include "OpenHDDNTFS.h"

#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <signal.h>
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

/* NTFS-3G messages are silenced; test builds can show them for diagnosis. */
static void quiet_ntfs_log(void)
{
    #ifdef OPENHDD_TESTING
    if (getenv("OPENHDD_TEST_NTFS_LOG")) {
        ntfs_log_set_handler(ntfs_log_handler_stderr);
        ntfs_log_set_levels(NTFS_LOG_LEVEL_ERROR | NTFS_LOG_LEVEL_PERROR |
                            NTFS_LOG_LEVEL_CRITICAL | NTFS_LOG_LEVEL_WARNING);
        return;
    }
    #endif
    ntfs_log_set_handler(ntfs_log_handler_null);
}

/* Large sequential I/O is what keeps USB and SSD transfers fast; the
   kernel splits it at the device's maximum transfer size. */
enum { IO_CHUNK = 4 * 1024 * 1024, MAX_ITEMS = 4096, PENDING_LENGTH = 49,
       UNIT_OVERHEAD = 1024 * 1024, MAX_DIRECTORIES = 100000,
       MAX_PENDING = 100000, MAX_JOURNAL = 16 * 1024 * 1024 };

static const char pending_prefix[] = ".OpenHDD-pending-";
/* A replaced file keeps this name, in its own folder, until the new file
   is published; the journal in the root says where each one is. */
static const char old_prefix[] = ".OpenHDD-old-";
static const char journal_name[] = ".OpenHDD-journal";

/* Last low-level failure, for the diagnostic line of the caller. */
static char last_error[256];
static char recovery_error[8192];

const char *oh_recovery_error(void) { return recovery_error; }

static void note_error(const char *format, ...)
{
    int saved = errno;
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(last_error, sizeof(last_error), format, arguments);
    va_end(arguments);
    errno = saved;
}

const char *oh_last_error(void)
{
    return last_error;
}

static volatile sig_atomic_t cancel_flag;

void oh_request_cancel(void)
{
    cancel_flag = 1;
}

int oh_cancel_requested(void)
{
    return cancel_flag != 0;
}

void oh_reset_cancel(void)
{
    cancel_flag = 0;
}

typedef struct {
    int fd;
    uint64_t size;
    uint64_t position;
    int is_device;
    int io_failed;
    /* Raw devices accept only whole sectors; 1 for image files. */
    uint32_t align;
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
    errno = 0;
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
    if (fsync(target->fd)) {
        note_error("device flush (fsync): %s", strerror(errno));
        target->io_failed = 1;
        return -1;
    }
    if (target->is_device && ioctl(target->fd, DKIOCSYNCHRONIZECACHE)) {
        note_error("drive cache flush: %s", strerror(errno));
        target->io_failed = 1;
        return -1;
    }
    return 0;
}

static s64 raw_io(Target *target, void *data, s64 count, s64 offset,
                  int writing)
{
    if (target->align > 1 && (offset % target->align || count % target->align)) {
        errno = EINVAL; /* what a raw device returns */
        target->io_failed = 1;
        return -1;
    }
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
            uint64_t slow = env_number("OPENHDD_TEST_SLOW_WRITE_MS");
            if (slow) usleep((useconds_t)(slow * 1000));
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
            note_error("device %s of %zu bytes at offset %llu: %s",
                       writing ? "write" : "read", request,
                       (unsigned long long)offset + done, strerror(errno));
            target->io_failed = 1;
            return -1;
        }
        done += (size_t)n;
    }
    return count;
}

/* NTFS-3G issues small metadata requests (boot sector, 1 KiB MFT records)
   that a raw device rejects. They are widened to whole sectors with a
   read-modify-write; aligned bulk data passes straight through. Buffers are
   bounced to page-aligned memory, which every raw driver accepts. */
static s64 bounded_io(Target *target, void *data, s64 count, s64 offset,
                      int writing)
{
    uint64_t align = target->align > 1 ? target->align : 1;
    if (count < 0 || offset < 0 || (uint64_t)offset > target->size ||
        (uint64_t)count > target->size - (uint64_t)offset) {
        target->io_failed = 1;
        errno = EINVAL;
        return -1;
    }
    int aligned = align == 1 ||
        ((uint64_t)offset % align == 0 && (uint64_t)count % align == 0);
    if (align == 1 || (aligned && ((uintptr_t)data & 4095) == 0))
        return raw_io(target, data, count, offset, writing);
    uint64_t start = (uint64_t)offset / align * align;
    uint64_t end = ((uint64_t)offset + (uint64_t)count + align - 1) / align * align;
    if (end > target->size) { target->io_failed = 1; errno = EINVAL; return -1; }
    uint64_t done = 0;
    void *bounce = NULL;
    size_t capacity = IO_CHUNK;
    if (posix_memalign(&bounce, 4096, capacity)) { errno = ENOMEM; return -1; }
    /* Walk the widened range in chunks; only the edges need a read first. */
    for (uint64_t block = start; block < end; ) {
        uint64_t span = end - block < capacity ? end - block : capacity;
        uint64_t lo = block > (uint64_t)offset ? block : (uint64_t)offset;
        uint64_t hi = block + span < (uint64_t)offset + (uint64_t)count ?
            block + span : (uint64_t)offset + (uint64_t)count;
        int partial = lo != block || hi != block + span;
        if ((!writing || partial) &&
            raw_io(target, bounce, (s64)span, (s64)block, 0) != (s64)span) {
            free(bounce);
            return -1;
        }
        if (writing) {
            memcpy((char *)bounce + (lo - block), (const char *)data + (lo - (uint64_t)offset),
                   (size_t)(hi - lo));
            if (raw_io(target, bounce, (s64)span, (s64)block, 1) != (s64)span) {
                free(bounce);
                return -1;
            }
        } else {
            memcpy((char *)data + (lo - (uint64_t)offset), (char *)bounce + (lo - block),
                   (size_t)(hi - lo));
        }
        done += hi - lo;
        block += span;
    }
    free(bounce);
    return (s64)done;
}

static uint32_t device_alignment(int fd)
{
    struct stat state;
    uint32_t block = 0;
    #ifdef OPENHDD_TESTING
    /* Emulates a raw device with this sector size on an image file. */
    uint64_t forced = env_number("OPENHDD_TEST_ALIGN");
    if (forced >= 512 && forced <= 65536 && !(forced & (forced - 1)))
        return (uint32_t)forced;
    #endif
    if (fstat(fd, &state) || !S_ISCHR(state.st_mode)) return 1;
    if (ioctl(fd, DKIOCGETBLOCKSIZE, &block) || block < 512 || block > 65536 ||
        (block & (block - 1))) return 0;
    return block;
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
    if (!strncasecmp(name, pending_prefix, sizeof(pending_prefix) - 1) ||
        !strcasecmp(name, journal_name))
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
    Target target = { .fd = target_fd, .size = target_size,
                      .align = device_alignment(target_fd) };
    *free_bytes = 0;
    *warnings = 0;
    if (!target.align) return EIO;
    quiet_ntfs_log();
    return volume_scan(&target, free_bytes, warnings);
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
    if (!strncasecmp(name, ".OpenHDD-", 9)) return 0;
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
    if (length > 1024 || (length && (path[0] == '/' || path[length - 1] == '/')) ||
        strstr(path, "//")) return 0;
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
        same = CFStringCompare(left, right, kCFCompareCaseInsensitive | kCFCompareNonliteral) ==
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

/* ------------------------------------------------------------------------ */
/* Batch phases: write all -> sync -> verify once -> publish -> complete     */
/* ------------------------------------------------------------------------ */

typedef struct {
    OHCopyProgress callback;
    void *context;
    size_t count;
    uint64_t done;
    uint64_t total;
} Work;

static void work_report(Work *work, int phase, size_t index)
{
    if (work->callback)
        work->callback(work->context, phase, index, work->count,
                       work->done, work->total);
}

static void work_advance(Work *work, int phase, size_t index, uint64_t units)
{
    work->done = work->total - work->done < units ? work->total : work->done + units;
    work_report(work, phase, index);
}

typedef struct {
    char pending[PENDING_LENGTH + 1];
    char old[PENDING_LENGTH + 1];     /* replaced file's temporary name */
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    uint64_t size;
    uint64_t inode;
    uint64_t directory_inode;         /* 0 until a new folder exists */
    uint64_t old_inode;
    uint64_t reference, old_reference;
    int replacing;                    /* an existing file is swapped out */
} Staged;

static int phase_error(Target *target)
{
    if (errno == ESTALE) return ESTALE; /* a source changed, not the drive */
    return target->io_failed ? EIO : (errno ? errno : EIO);
}

/* prefix + 32 random hex digits; the buffer holds PENDING_LENGTH + 1. */
static void make_temporary_name(char name[PENDING_LENGTH + 1], const char *prefix)
{
    unsigned char random_bytes[16];
    static const char hex[] = "0123456789abcdef";
    size_t length = strlen(prefix);
    arc4random_buf(random_bytes, sizeof(random_bytes));
    memcpy(name, prefix, length);
    for (size_t i = 0; i < sizeof(random_bytes); ++i) {
        name[length + i * 2] = hex[random_bytes[i] >> 4];
        name[length + i * 2 + 1] = hex[random_bytes[i] & 15];
    }
    name[length + 32] = 0;
}

static void make_pending_name(char pending[PENDING_LENGTH + 1])
{
    make_temporary_name(pending, pending_prefix);
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

static int split_path(const char *path, char *parent, size_t parent_size,
                      const char **leaf);
static int protected_path(const char *path);
static int unlink_name(ntfs_volume *volume, const char *parent_path,
                       const char *name);
static int rename_entry(ntfs_volume *volume, const char *parent_path,
                        const char *old_name, const char *new_name,
                        const char *temporary);
static int make_directory(ntfs_volume *volume, const char *parent_path,
                          const char *name);

static const char *item_directory(const OHCopyItem *item)
{
    return item->directory ? item->directory : "";
}

/* Case-folded copy of a name, for comparisons the way Windows sees them. */
static char *fold_key(const char *value)
{
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, value,
                                                   kCFStringEncodingUTF8);
    if (!string) return NULL;
    CFMutableStringRef folded = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
    CFRelease(string);
    if (!folded) return NULL;
    CFStringNormalize(folded, kCFStringNormalizationFormC);
    CFStringFold(folded, kCFCompareCaseInsensitive, NULL);
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(folded), kCFStringEncodingUTF8) + 1;
    char *out = malloc((size_t)capacity);
    if (out && !CFStringGetCString(folded, out, capacity, kCFStringEncodingUTF8)) {
        free(out);
        out = NULL;
    }
    CFRelease(folded);
    return out;
}

/* Like oh_ntfs_resolve_directory, but never through a junction or link. */
static int resolve_plain_directory(OHNTFSVolume *volume, const char *path,
                                   uint64_t *inode)
{
    uint64_t current = FILE_root;
    char *copy = strdup(path ? path : "");
    if (!copy) return ENOMEM;
    int error = 0;
    char *cursor = copy, *component;
    while (!error && (component = strsep(&cursor, "/"))) {
        if (!*component) continue;
        OHNTFSItem item;
        error = oh_ntfs_lookup(volume, current, component, &item);
        if (!error && item.special) error = ENOTSUP;
        if (!error && item.kind != 2) error = ENOTDIR;
        if (!error) current = item.inode;
    }
    free(copy);
    if (!error) *inode = current;
    return error;
}

/* Content changes move the modification time. The status-change time is
   deliberately ignored: macOS updates it when it merely tags a file the
   user picked (com.apple.macl), which says nothing about its bytes. */
static int source_unchanged(int fd, const struct stat *before)
{
    struct stat after;
    return !fstat(fd, &after) && after.st_dev == before->st_dev &&
        after.st_ino == before->st_ino && after.st_size == before->st_size &&
        after.st_mtimespec.tv_sec == before->st_mtimespec.tv_sec &&
        after.st_mtimespec.tv_nsec == before->st_mtimespec.tv_nsec;
}

/* Stage 2: every file is written under its temporary name in the root, in
   one read-write mount, then the device is synced once. */
static int write_all(Target *target, const OHCopyItem *items,
                     const struct stat *sources, Staged *staged, size_t count,
                     unsigned char *buffer, Work *work, size_t *failed_index)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = 0;
    for (size_t i = 0; i < count && !result; ++i) {
        *failed_index = i;
        ntfs_inode *created = NULL, *root = NULL;
        ntfs_attr *data = NULL;
        ntfschar *wide = NULL;
        CC_SHA256_CTX sha;
        result = -1;
        if (cancel_flag) { errno = ECANCELED; goto next; }
        int length = ntfs_mbstoucs(staged[i].pending, &wide);
        if (length <= 0 || length > 255) goto next;
        /* The root is opened for each file and closed right after the
           create: once its index grows past the index root, a child closed
           while the parent's index is still unsynced cannot find its own
           entry to update. */
        root = ntfs_inode_open(volume, FILE_root);
        created = root ? ntfs_create(root, const_cpu_to_le32(0), wide, (u8)length, S_IFREG) : NULL;
        if (!created) { note_error("create of file %zu failed (%d)", i + 1, errno); goto next; }
        if (ntfs_inode_close(root)) {
            root = NULL;
            note_error("folder update for file %zu failed (%d)", i + 1, errno);
            goto next;
        }
        root = NULL;
        data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
        if (!data) {
            if (errno != ENOENT ||
                ntfs_attr_add(created, AT_DATA, AT_UNNAMED, 0, NULL, 0)) {
                note_error("data stream of file %zu failed (%d)", i + 1, errno);
                goto next;
            }
            data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
            if (!data) { note_error("data stream of file %zu failed (%d)", i + 1, errno); goto next; }
        }
        if (ntfs_attr_truncate_solid(data, sources[i].st_size)) {
            note_error("allocation of file %zu failed (%d)", i + 1, errno);
            goto next;
        }
        if (!CC_SHA256_Init(&sha) ||
            lseek(items[i].source_fd, 0, SEEK_SET) != 0) goto next;
        for (uint64_t offset = 0; offset < (uint64_t)sources[i].st_size; ) {
            #ifdef OPENHDD_TESTING
            if (offset && getenv("OPENHDD_TEST_FAIL_AFTER_FIRST_CHUNK")) {
                errno = EIO;
                goto next;
            }
            #endif
            if (cancel_flag) { errno = ECANCELED; goto next; }
            size_t amount = (uint64_t)sources[i].st_size - offset;
            if (amount > IO_CHUNK) amount = IO_CHUNK;
            ssize_t got = 0;
            while (got < (ssize_t)amount) {
                ssize_t n = read(items[i].source_fd, buffer + got, amount - (size_t)got);
                if (n < 0 && errno == EINTR) continue;
                if (n <= 0) break;
                got += n;
            }
            if (got != (ssize_t)amount) {
                note_error("read of source file %zu at offset %llu failed", i + 1,
                           (unsigned long long)offset);
                errno = got < 0 ? errno : ESTALE;
                goto next;
            }
            if (!CC_SHA256_Update(&sha, buffer, (CC_LONG)amount)) goto next;
            for (ssize_t done = 0; done < got; ) {
                s64 written = ntfs_attr_pwrite(data, (s64)(offset + done),
                                                got - done, buffer + done);
                if (written <= 0) {
                    note_error("write of file %zu at offset %llu failed (%d)", i + 1,
                               (unsigned long long)(offset + done), errno);
                    goto next;
                }
                done += written;
            }
            offset += amount;
            work_advance(work, OH_PHASE_WRITE, i, amount);
            #ifdef OPENHDD_TESTING
            if (getenv("OPENHDD_TEST_ABORT_AFTER_FIRST_CHUNK"))
                _exit(86); /* Emulate a crash before close or sync. */
            #endif
        }
        if (!source_unchanged(items[i].source_fd, &sources[i])) {
            note_error("source file %zu changed while it was being copied", i + 1);
            errno = ESTALE;
            goto next;
        }
        if (!CC_SHA256_Final(staged[i].digest, &sha)) goto next;
        staged[i].size = (uint64_t)sources[i].st_size;
        result = 0;
    next:;
        int saved = errno; /* the closes below may overwrite it */
        free(wide);
        if (data) ntfs_attr_close(data);
        if (root && ntfs_inode_close(root)) result = -1;
        if (created && ntfs_inode_close(created)) {
            note_error("close of file %zu failed (%d%s)", i + 1, errno, target->io_failed ? ", device I/O" : "");
            saved = errno;
            result = -1;
        }
        if (result) errno = saved;
    }
    int failure = result ? errno : 0;
    work_report(work, OH_PHASE_SYNC, count ? count - 1 : 0);
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (failure) errno = failure;
    return result;
}

/* The names of one folder, read in a single listing and sorted by their
   NTFS case-insensitive key, so thousands of files can be checked against
   a large folder without re-reading it for every file. */
typedef struct {
    uint16_t key[255];
    uint16_t name[255];
    int length;
    uint64_t inode;
    int directory;
} IndexEntry;

typedef struct {
    uint64_t inode;
    int valid;
    IndexEntry *entries;
    size_t count, capacity;
} FolderIndex;

static int compare_index_keys(const uint16_t *a, int a_length,
                              const uint16_t *b, int b_length)
{
    int shorter = a_length < b_length ? a_length : b_length;
    for (int i = 0; i < shorter; ++i)
        if (a[i] != b[i]) return a[i] < b[i] ? -1 : 1;
    return a_length == b_length ? 0 : a_length < b_length ? -1 : 1;
}

static int compare_entries(const void *a, const void *b)
{
    const IndexEntry *left = a, *right = b;
    return compare_index_keys(left->key, left->length, right->key, right->length);
}

static int add_index_entry(void *opaque, const uint16_t *key, const uint16_t *name,
                           int length, uint64_t inode, int directory)
{
    FolderIndex *index = opaque;
    if (index->count == index->capacity) {
        size_t capacity = index->capacity ? index->capacity * 2 : 256;
        IndexEntry *grown = realloc(index->entries, capacity * sizeof(*grown));
        if (!grown) return ENOMEM;
        index->entries = grown;
        index->capacity = capacity;
    }
    IndexEntry *entry = &index->entries[index->count++];
    memcpy(entry->key, key, (size_t)length * sizeof(uint16_t));
    memcpy(entry->name, name, (size_t)length * sizeof(uint16_t));
    entry->length = length;
    entry->inode = inode;
    entry->directory = directory;
    return 0;
}

/* Makes `index` describe folder `inode`, reading it only when it changes. */
static int index_folder(OHNTFSVolume *volume, FolderIndex *index, uint64_t inode)
{
    if (index->valid && index->inode == inode) return 0;
    index->valid = 0;
    index->count = 0;
    int status = oh_ntfs_list_keys(volume, inode, add_index_entry, index);
    if (status) return status;
    qsort(index->entries, index->count, sizeof(*index->entries), compare_entries);
    index->inode = inode;
    index->valid = 1;
    return 0;
}

/* The entry whose name equals `name` ignoring case, or NULL; *exact tells
   whether the stored name is identical, letter case included. */
static int index_find(OHNTFSVolume *volume, const FolderIndex *index,
                      const char *name, const IndexEntry **found, int *exact)
{
    uint16_t *key = NULL;
    int length = 0;
    int status = oh_ntfs_name_key(volume, name, &key, &length);
    if (status) return status;
    ntfschar *wide = NULL;
    int wide_length = ntfs_mbstoucs(name, &wide);
    *found = NULL;
    size_t low = 0, high = index->count;
    while (low < high) {
        size_t middle = (low + high) / 2;
        int order = compare_index_keys(index->entries[middle].key,
                                       index->entries[middle].length, key, length);
        if (!order) { *found = &index->entries[middle]; break; }
        if (order < 0) low = middle + 1; else high = middle;
    }
    if (exact) *exact = *found && wide_length == (*found)->length &&
        !memcmp(wide, (*found)->name, (size_t)wide_length * sizeof(uint16_t));
    free(wide);
    free(key);
    return 0;
}

static void index_free(FolderIndex *index)
{
    free(index->entries);
    index->entries = NULL;
    index->count = index->capacity = 0;
    index->valid = 0;
}

/* Resolves each item's folder once folders exist; consecutive items usually
   share a folder, so the last answer is kept. */
typedef struct {
    const char *path;
    uint64_t inode;
} FolderCache;

static int item_folder(OHNTFSVolume *volume, FolderCache *cache,
                       const OHCopyItem *item, uint64_t *inode)
{
    const char *path = item_directory(item);
    if (cache->path && !strcmp(cache->path, path)) { *inode = cache->inode; return 0; }
    int status = resolve_plain_directory(volume, path, inode);
    if (!status) { cache->path = path; cache->inode = *inode; }
    return status;
}

/* Stage 3: the only full read-back. On a raw device it comes from the
   drive, not from a cache. Final names are re-checked in the same view:
   still free for a new file, still the same old file for a replacement. */
static int verify_all(Target *target, const OHCopyItem *items, Staged *staged,
                      size_t count, unsigned char *buffer, Work *work,
                      size_t *failed_index)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    if (warnings) status = EBUSY;
    FolderCache cache = { 0 };
    FolderIndex index = { 0 };
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        OHNTFSItem item;
        CC_SHA256_CTX sha;
        unsigned char actual[CC_SHA256_DIGEST_LENGTH];
        const IndexEntry *existing = NULL;
        if (item_folder(volume, &cache, &items[i], &staged[i].directory_inode) ||
            index_folder(volume, &index, staged[i].directory_inode) ||
            index_find(volume, &index, items[i].destination_name, &existing, NULL)) {
            status = EIO;
            break;
        }
        if (staged[i].replacing) {
            if (!existing || existing->inode != staged[i].old_inode) { status = EIO; break; }
        } else if (existing) { status = EEXIST; break; }
        if (oh_ntfs_lookup(volume, FILE_root, staged[i].pending, &item) ||
            item.kind != 1 || item.size != staged[i].size ||
            !CC_SHA256_Init(&sha)) { status = EIO; break; }
        for (uint64_t offset = 0; offset < staged[i].size; ) {
            if (cancel_flag) { status = ECANCELED; break; }
            uint64_t amount = staged[i].size - offset;
            if (amount > IO_CHUNK) amount = IO_CHUNK;
            if (oh_ntfs_read(volume, item.inode, offset, buffer, amount) !=
                (int64_t)amount ||
                !CC_SHA256_Update(&sha, buffer, (CC_LONG)amount)) {
                status = EIO;
                break;
            }
            offset += amount;
            work_advance(work, OH_PHASE_VERIFY, i, amount);
        }
        if (status) break;
        if (!staged[i].size &&
            oh_ntfs_read(volume, item.inode, 0, buffer, 1) != 0) { status = EIO; break; }
        if (!CC_SHA256_Final(actual, &sha) ||
            memcmp(actual, staged[i].digest, sizeof(actual))) { status = EIO; break; }
        staged[i].inode = item.inode;
        staged[i].reference = item.reference;
    }
    index_free(&index);
    oh_ntfs_close(volume);
    return target->io_failed ? EIO : status;
}

/* Stage 2, before any existing file is touched: folders that do not exist
   yet are created, parents first, in one mount. */
static int create_directories(Target *target, const char *const *directories,
                              const unsigned char *missing, size_t count,
                              Work *work, size_t *failed_index)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = 0;
    for (size_t i = 0; i < count && !result; ++i) {
        if (!missing[i]) continue;
        *failed_index = i;
        char parent[4097];
        const char *leaf = NULL;
        result = split_path(directories[i], parent, sizeof(parent), &leaf) ? -1 :
            make_directory(volume, parent, leaf);
        work_advance(work, OH_PHASE_WRITE, 0, UNIT_OVERHEAD / 8);
    }
    int failure = result ? errno : 0;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (failure) errno = failure;
    return result;
}

/* The recovery journal: one line per replacement, "folder TAB old-name TAB
   final-name". Written and read back before the first old file is renamed,
   removed only after every old file is gone. */
static int write_journal_text(Target *target, int version, const char *text,
                              size_t length);

static int write_journal(Target *target, const OHCopyItem *items,
                         const Staged *staged, size_t count)
{
    size_t length = 0;
    for (size_t i = 0; i < count; ++i)
        if (staged[i].replacing)
            length += strlen(item_directory(&items[i])) + strlen(staged[i].old) +
                strlen(items[i].destination_name) + 3;
    if (!length) return 0;
    length += 101 * count; /* type, two MFT references and SHA-256 */
    if (length > MAX_JOURNAL) { errno = EFBIG; return -1; }
    char *text = malloc(length + 1);
    if (!text) return -1;
    size_t used = 0;
    for (size_t i = 0; i < count; ++i)
        if (staged[i].replacing) {
            char digest[65];
            for (size_t j = 0; j < sizeof(staged[i].digest); ++j)
                snprintf(digest + 2 * j, 3, "%02x", staged[i].digest[j]);
            used += (size_t)snprintf(text + used, length + 1 - used, "R\t%s\t%s\t%s\t%016llx\t%016llx\t%s\n",
                                     item_directory(&items[i]), staged[i].old,
                                     items[i].destination_name,
                                     (unsigned long long)staged[i].old_reference,
                                     (unsigned long long)staged[i].reference, digest);
        }
    int result = write_journal_text(target, 2, text, used);
    free(text);
    return result;
}

/* The journal is written and read back before the first change it
   describes, in its own mount. */
static int write_journal_text(Target *target, int version, const char *text,
                              size_t length)
{
    /* Integrity check, not authentication: the whole on-disk file remains
       untrusted and recovery validates every record and its target. */
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char header[96], hex[65];
    if (!CC_SHA256(text, (CC_LONG)length, digest)) return -1;
    for (size_t i = 0; i < sizeof(digest); ++i)
        snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    int header_length = snprintf(header, sizeof(header), "OpenHDD-Journal\t%d\t%s\n",
                                 version, hex);
    if (length > MAX_JOURNAL - (size_t)header_length) { errno = EFBIG; return -1; }
    int result = -1;
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
    ntfschar *wide = NULL;
    int wide_length = ntfs_mbstoucs(journal_name, &wide);
    ntfs_inode *created = root && wide_length > 0 ?
        ntfs_create(root, const_cpu_to_le32(0), wide, (u8)wide_length, S_IFREG) : NULL;
    ntfs_attr *data = NULL;
    if (created) {
        data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
        if (!data && errno == ENOENT &&
            !ntfs_attr_add(created, AT_DATA, AT_UNNAMED, 0, NULL, 0))
            data = ntfs_attr_open(created, AT_DATA, AT_UNNAMED, 0);
    }
    if (data && ntfs_attr_pwrite(data, 0, header_length, header) == header_length &&
        ntfs_attr_pwrite(data, header_length, (s64)length, text) == (s64)length)
        result = 0;
    int failure = result ? errno : 0;
    if (data) ntfs_attr_close(data);
    if (created && ntfs_inode_close(created)) result = -1;
    if (root && ntfs_inode_close(root)) result = -1;
    free(wide);
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (result) { if (failure) errno = failure; return -1; }

    OHNTFSVolume *view = NULL;
    uint32_t warnings = 0;
    OHNTFSItem item;
    size_t total = length + (size_t)header_length;
    char *check = malloc(total);
    int status = check ? readonly_open(target, &view, &warnings) : ENOMEM;
    if (!status && (oh_ntfs_lookup(view, FILE_root, journal_name, &item) ||
                    item.size != total ||
                    oh_ntfs_read(view, item.inode, 0, check, total) != (int64_t)total ||
                    memcmp(check, header, (size_t)header_length) ||
                    memcmp(check + header_length, text, length)))
        status = EIO;
    if (view) oh_ntfs_close(view);
    free(check);
    if (status || target->io_failed) { errno = target->io_failed ? EIO : status; return -1; }
    return 0;
}

/* Version 3 journal, written right after stage 2 created new folders and
   removed before anything is published: one line per folder, "D TAB parent
   TAB name TAB MFT reference", parents first. Recovery removes a listed
   folder only while it keeps that identity and is empty, so an interrupted
   copy leaves no empty destination behind and no data is ever at stake.
   Returns 1 when written, 0 when there are too many folders to journal
   (then they stay, as before version 3), -1 on failure. */
static int write_folder_journal(Target *target, const char *const *directories,
                                const unsigned char *missing, size_t count)
{
    size_t lines = 0, length = 0;
    for (size_t i = 0; i < count; ++i)
        if (missing[i]) {
            ++lines;
            length += strlen(directories[i]) + 24; /* type, tabs, reference */
        }
    if (!lines || lines > MAX_ITEMS || length > MAX_JOURNAL - 96) return 0;
    char *text = malloc(length + 1);
    OHNTFSVolume *view = NULL;
    uint32_t warnings = 0;
    int status = text ? readonly_open(target, &view, &warnings) : ENOMEM;
    if (!status && warnings) status = EBUSY;
    size_t used = 0;
    for (size_t i = 0; i < count && !status; ++i) {
        if (!missing[i]) continue;
        char parent[4097];
        const char *leaf = NULL;
        uint64_t parent_inode = 0;
        OHNTFSItem item;
        status = split_path(directories[i], parent, sizeof(parent), &leaf) ? EINVAL :
            resolve_plain_directory(view, parent, &parent_inode);
        if (!status) status = oh_ntfs_lookup(view, parent_inode, leaf, &item);
        if (!status && (item.kind != 2 || item.special)) status = EIO;
        if (!status)
            used += (size_t)snprintf(text + used, length + 1 - used, "D\t%s\t%s\t%016llx\n",
                                     parent, leaf, (unsigned long long)item.reference);
    }
    if (view) oh_ntfs_close(view);
    if (!status && target->io_failed) status = EIO;
    int result = status ? -1 : write_journal_text(target, 3, text, used);
    free(text);
    if (status) { errno = status; return -1; }
    return result ? -1 : 1;
}

static int remove_journal(Target *target)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = unlink_name(volume, "", journal_name);
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    return result;
}

/* Stage 4: every verified file gets its final name, in one mount. A file
   being replaced first moves aside under its temporary old name. */
static int publish_all(Target *target, const OHCopyItem *items,
                       const Staged *staged, size_t count, Work *work,
                       size_t *failed_index)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = 0;
    for (size_t i = 0; i < count && !result; ++i) {
        *failed_index = i;
        ntfschar *wide = NULL;
        ntfs_inode *directory = NULL, *source = NULL;
        result = -1;
        if (staged[i].replacing &&
            rename_entry(volume, item_directory(&items[i]),
                         items[i].destination_name, staged[i].old, NULL)) goto next;
        #ifdef OPENHDD_TESTING
        if (staged[i].replacing && getenv("OPENHDD_TEST_ABORT_AFTER_ASIDE")) {
            ntfs_umount(volume, FALSE);
            durable_sync(target);
            _exit(86); /* the old file is aside, the new one not yet linked */
        }
        #endif
        directory = open_directory(volume, item_directory(&items[i]));
        if (!directory || directory->mft_no != staged[i].directory_inode) goto next;
        source = ntfs_pathname_to_inode(volume, NULL, staged[i].pending);
        if (!source || source->mft_no != staged[i].inode) goto next;
        ntfs_inode *existing = ntfs_pathname_to_inode(volume, directory,
                                                       items[i].destination_name);
        if (existing) { ntfs_inode_close(existing); errno = EEXIST; goto next; }
        if (errno != ENOENT) goto next;
        int length = ntfs_mbstoucs(items[i].destination_name, &wide);
        if (length <= 0 || length > 255 ||
            ntfs_link(source, directory, wide, (u8)length)) goto next;
        result = 0;
        #ifdef OPENHDD_TESTING
        if (getenv("OPENHDD_TEST_FAIL_AFTER_LINK")) { errno = EIO; result = -1; }
        #endif
    next:
        free(wide);
        if (source && ntfs_inode_close(source)) result = -1;
        if (directory && ntfs_inode_close(directory)) result = -1;
        work_advance(work, OH_PHASE_PUBLISH, i, UNIT_OVERHEAD / 2);
    }
    int failure = result ? errno : 0;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (failure) errno = failure;
    return result;
}

/* Checks names and identities without re-reading file contents: publish
   and completion only add or remove directory entries. */
static int check_names(Target *target, const OHCopyItem *items,
                       const Staged *staged, size_t count, int pending_expected,
                       size_t *failed_index)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    if (warnings) status = EBUSY;
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        OHNTFSItem final_item, pending_item, old_item;
        int pending = oh_ntfs_lookup(volume, FILE_root, staged[i].pending,
                                     &pending_item);
        if (oh_ntfs_lookup(volume, staged[i].directory_inode,
                           items[i].destination_name, &final_item) ||
            final_item.inode != staged[i].inode || final_item.kind != 1 ||
            final_item.size != staged[i].size ||
            final_item.hard_link_count != (pending_expected ? 2u : 1u) ||
            (pending_expected ? pending != 0 || pending_item.inode != staged[i].inode :
                                pending != ENOENT))
            status = EIO;
        if (!status && staged[i].replacing) {
            int old = oh_ntfs_lookup(volume, staged[i].directory_inode,
                                     staged[i].old, &old_item);
            if (pending_expected ? old != 0 || old_item.inode != staged[i].old_inode :
                                   old != ENOENT)
                status = EIO;
        }
    }
    oh_ntfs_close(volume);
    return target->io_failed ? EIO : status;
}

/* Stage 5: temporary names and replaced files are removed, one directory
   entry at a time, in a single mount. */
static int complete_all(Target *target, const OHCopyItem *items,
                        const Staged *staged, size_t count, Work *work,
                        size_t *failed_index)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = 0;
    for (size_t i = 0; i < count && !result; ++i) {
        *failed_index = i;
        ntfschar *wide = NULL;
        ntfs_inode *directory = open_directory(volume, item_directory(&items[i]));
        ntfs_inode *final = directory ?
            ntfs_pathname_to_inode(volume, directory, items[i].destination_name) : NULL;
        ntfs_inode *temporary = ntfs_pathname_to_inode(volume, NULL, staged[i].pending);
        ntfs_inode *root = ntfs_inode_open(volume, FILE_root);
        int length = ntfs_mbstoucs(staged[i].pending, &wide);
        int valid = directory && final && temporary && root &&
            final->mft_no == staged[i].inode && temporary->mft_no == staged[i].inode &&
            le16_to_cpu(temporary->mrec->link_count) == 2 &&
            length > 0 && length <= 255;
        if (final) ntfs_inode_close(final);
        if (directory) ntfs_inode_close(directory);
        if (!valid) {
            if (temporary) ntfs_inode_close(temporary);
            if (root) ntfs_inode_close(root);
            errno = EIO;
            result = -1;
        } else if (ntfs_delete(volume, staged[i].pending, temporary, root,
                               wide, (u8)length)) {
            result = -1; /* ntfs_delete closes both inodes */
        }
        free(wide);
        if (!result && staged[i].replacing)
            result = unlink_name(volume, item_directory(&items[i]), staged[i].old);
        work_advance(work, OH_PHASE_FINISH, i, UNIT_OVERHEAD / 2);
    }
    int failure = result ? errno : 0;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (failure) errno = failure;
    return result;
}

typedef struct {
    char name[PENDING_LENGTH + 1];
    int directory, journaled;
} PendingEntry;

typedef struct {
    PendingEntry *entries;
    size_t count, capacity;
    int journal;
} PendingList;

static int temporary_name(const char *name, const char *prefix)
{
    size_t length = strlen(prefix);
    if (strlen(name) != length + 32 || strncmp(name, prefix, length)) return 0;
    return strspn(name + length, "0123456789abcdef") == 32;
}

static int collect_pending(void *opaque, const char *name,
                           const OHNTFSItem *item)
{
    PendingList *list = opaque;
    if (!strcasecmp(name, journal_name)) {
        if (strcmp(name, journal_name) || item->kind != 1 || item->special ||
            item->hard_link_count != 1) return EPERM;
        list->journal = 1;
        return 0;
    }
    if (strncasecmp(name, pending_prefix, sizeof(pending_prefix) - 1)) return 0;
    if (!temporary_name(name, pending_prefix) || item->special ||
        (item->kind != 1 && item->kind != 2) || list->count == MAX_PENDING)
        return EPERM;
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 64;
        void *grown = realloc(list->entries, capacity * sizeof(*list->entries));
        if (!grown) return ENOMEM;
        list->entries = grown;
        list->capacity = capacity;
    }
    PendingEntry *entry = &list->entries[list->count++];
    memcpy(entry->name, name, PENDING_LENGTH + 1);
    entry->directory = item->kind == 2;
    entry->journaled = 0;
    return 0;
}

static int read_journal(Target *target, char **text)
{
    OHNTFSVolume *view = NULL;
    uint32_t warnings = 0;
    OHNTFSItem item;
    int status = readonly_open(target, &view, &warnings);
    if (status) return status;
    status = warnings ? EBUSY : oh_ntfs_lookup(view, FILE_root, journal_name, &item);
    if (!status && (item.kind != 1 || item.special || item.hard_link_count != 1 ||
                   !item.size || item.size > MAX_JOURNAL)) status = EPERM;
    char *buffer = status ? NULL : malloc(item.size + 1);
    if (!status && !buffer) status = ENOMEM;
    if (!status && oh_ntfs_read(view, item.inode, 0, buffer, item.size) !=
        (int64_t)item.size) status = EIO;
    oh_ntfs_close(view);
    if (!status && (memchr(buffer, 0, item.size) || buffer[item.size - 1] != '\n'))
        status = EINVAL;
    if (status || target->io_failed) { free(buffer); return target->io_failed ? EIO : status; }
    buffer[item.size] = 0;
    *text = buffer;
    return 0;
}

typedef struct {
    char type;
    const char *folder[2], *name[2];
    uint64_t reference[2]; /* zero only for legacy journals */
    const char *digest; /* expected new-file SHA-256 for a replacement */
    int action; /* 0: already settled/undone, 1: drop first name, 2: restore it,
                   3: remove an empty folder the interrupted copy created */
    uint64_t inode; /* folder records: the folder's record while it is a candidate */
} RecoveryEntry;

/* Diagnostic only: paths are expectations, never a claim that data was found.
   Escape control bytes so on-disk names cannot forge additional report lines. */
static void recovery_path(char *out, size_t size, const char *folder, const char *name)
{
    snprintf(out, size, "/%s%s%s", folder, *folder ? "/" : "", name);
    for (unsigned char *p = (unsigned char *)out; *p; ++p)
        if (*p < 32 || *p == 127) *p = '?';
}

static int recovery_failure(int code, const char *reason, size_t row, const RecoveryEntry *entry)
{
    char first[2100] = "", second[2100] = "";
    if (entry) {
        recovery_path(first, sizeof(first), entry->folder[0], entry->name[0]);
        recovery_path(second, sizeof(second), entry->folder[1], entry->name[1]);
    }
    snprintf(recovery_error, sizeof(recovery_error),
             "Recovery reason: %s\nRecovery record: %zu\n"
             "Expected path 1: %s\nExpected path 2: %s\n"
             "Expected MFT 1: %016llx\nExpected MFT 2: %016llx\n",
             reason, row, first, second,
             (unsigned long long)(entry ? entry->reference[0] : 0),
             (unsigned long long)(entry ? entry->reference[1] : 0));
    return code;
}

static int recovery_directory(const char *path)
{
    return oh_ntfs_valid_directory_path(path) && !protected_path(path);
}

static int recovery_reference(const char *value, uint64_t *reference)
{
    if (strlen(value) != 16 || strspn(value, "0123456789abcdef") != 16) return EINVAL;
    *reference = strtoull(value, NULL, 16);
    return MREF(*reference) < FILE_first_user || !MSEQNO(*reference) ? EINVAL : 0;
}

/* Parse the entire untrusted journal before any write. Version 2 binds
   entries to MFT record/sequence pairs and detects torn/truncated text.
   Legacy records remain readable, but ambiguous replacements are refused. */
static int parse_journal(char *text, RecoveryEntry *entries, size_t *count)
{
    char prefix[] = "OpenHDD-Journal\t2\t";
    if (!strncmp(text, "OpenHDD-Journal\t3\t", sizeof(prefix) - 1)) prefix[16] = '3';
    int versioned = !strncmp(text, prefix, sizeof(prefix) - 1);
    int folders = versioned && prefix[16] == '3';
    if (!versioned && !strncmp(text, "OpenHDD-Journal", 15))
        return recovery_failure(ENOTSUP, "unsupported-version", 0, NULL);
    if (versioned) {
        char *body = strchr(text, '\n');
        if (!body || body - text != (ptrdiff_t)(sizeof(prefix) - 1 + 64))
            return recovery_failure(EINVAL, "invalid-header", 0, NULL);
        unsigned char digest[CC_SHA256_DIGEST_LENGTH];
        char hex[65];
        ++body;
        if (!CC_SHA256(body, (CC_LONG)strlen(body), digest)) return EIO;
        for (size_t i = 0; i < sizeof(digest); ++i)
            snprintf(hex + 2 * i, 3, "%02x", digest[i]);
        if (memcmp(text + sizeof(prefix) - 1, hex, 64))
            return recovery_failure(EINVAL, "checksum-mismatch", 0, NULL);
        text = body;
    }
    char *line;
    while ((line = strsep(&text, "\n"))) {
        if (!*line) { if (text) return EINVAL; break; }
        recovery_failure(EINVAL, "invalid-record", *count + 1, NULL);
        if (*count == MAX_ITEMS) return EFBIG;
        char *fields[7], *field;
        size_t n = 0;
        while ((field = strsep(&line, "\t"))) {
            if (n == 7) return EINVAL;
            fields[n++] = field;
        }
        if (strlen(fields[0]) != 1) return EINVAL;
        char type = fields[0][0];
        if (folders != (type == 'D')) return EINVAL; /* D only, and only in v3 */
        if (type == 'D') {
            if (n != 4) return EINVAL;
            RecoveryEntry *entry = &entries[(*count)++];
            entry->type = type;
            entry->folder[0] = entry->folder[1] = fields[1];
            entry->name[0] = entry->name[1] = fields[2];
            if (!recovery_directory(fields[1]) || !oh_ntfs_valid_new_name(fields[2]) ||
                (!*fields[1] && protected_path(fields[2])))
                return EPERM;
            if (recovery_reference(fields[3], &entry->reference[0])) return EINVAL;
            entry->reference[1] = entry->reference[0];
            continue;
        }
        size_t expected = type == 'L' ? 5 : 4;
        if (type != 'L' && type != 'R' && type != 'C') return EINVAL;
        if (versioned) expected += type == 'R' ? 3 : 1;
        if (n != expected) return EINVAL;
        RecoveryEntry *entry = &entries[(*count)++];
        entry->type = type;
        entry->folder[0] = fields[1];
        entry->name[0] = fields[2];
        entry->folder[1] = type == 'L' ? fields[3] : fields[1];
        entry->name[1] = type == 'L' ? fields[4] : fields[3];
        int folders_valid = recovery_directory(entry->folder[0]) && recovery_directory(entry->folder[1]);
        int final_valid = oh_ntfs_valid_new_name(entry->name[1]) &&
            (*entry->folder[1] || !protected_path(entry->name[1]));
        int first_valid = type == 'L' ?
            oh_ntfs_valid_new_name(entry->name[0]) &&
                (*entry->folder[0] || !protected_path(entry->name[0])) :
            temporary_name(entry->name[0], type == 'R' ? old_prefix : pending_prefix);
        if (!folders_valid || !final_valid || !first_valid)
            return EPERM;
        if (versioned) {
            if (recovery_reference(fields[type == 'L' ? 5 : 4], &entry->reference[0])) return EINVAL;
            entry->reference[1] = entry->reference[0];
            if (type == 'R') {
                if (recovery_reference(fields[5], &entry->reference[1]) ||
                    strlen(fields[6]) != 64 || strspn(fields[6], "0123456789abcdef") != 64)
                    return EINVAL;
                entry->digest = fields[6];
            }
        }
    }
    if (*count) recovery_error[0] = 0;
    return *count ? 0 : EINVAL;
}

typedef struct {
    uint64_t folder;
    uint16_t *key;
    int length;
    size_t row;
} RecoveryName;

static int compare_recovery_names(const void *a, const void *b)
{
    const RecoveryName *left = a, *right = b;
    if (left->folder != right->folder) return left->folder < right->folder ? -1 : 1;
    return compare_index_keys(left->key, left->length, right->key, right->length);
}

/* A surviving inode is insufficient evidence that the replacement's bytes
   survived repair. Recheck its saved digest before discarding the backup. */
static int verify_recovered_file(OHNTFSVolume *view, const OHNTFSItem *item,
                                  const char *expected)
{
    unsigned char *buffer = malloc(IO_CHUNK);
    if (!buffer) return ENOMEM;
    CC_SHA256_CTX sha;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    char hex[65];
    int status = CC_SHA256_Init(&sha) ? 0 : EIO;
    for (uint64_t offset = 0; offset < item->size && !status; ) {
        uint64_t amount = item->size - offset;
        if (amount > IO_CHUNK) amount = IO_CHUNK;
        if (oh_ntfs_read(view, item->inode, offset, buffer, amount) != (int64_t)amount ||
            !CC_SHA256_Update(&sha, buffer, (CC_LONG)amount)) status = EIO;
        offset += amount;
    }
    if (!status && !CC_SHA256_Final(digest, &sha)) status = EIO;
    if (!status) {
        for (size_t i = 0; i < sizeof(digest); ++i)
            snprintf(hex + 2 * i, 3, "%02x", digest[i]);
        if (strcmp(hex, expected)) status = EIO;
    }
    free(buffer);
    return status;
}

typedef struct {
    const RecoveryEntry *entries;
    size_t count;
    int occupied;
} FolderChildren;

/* A child keeps its folder unless it is itself a listed folder already
   planned for removal (deeper folders are planned first). */
static int count_folder_child(void *opaque, const char *name, const OHNTFSItem *item)
{
    (void)name;
    FolderChildren *children = opaque;
    int removable = 0;
    for (size_t i = 0; i < children->count && !removable; ++i)
        removable = children->entries[i].action == 3 &&
            children->entries[i].inode == item->inode;
    if (!removable) children->occupied = 1;
    return 0;
}

/* Folder records never block recovery: a folder that is gone, renamed,
   replaced by another record or no longer empty is simply left as it is.
   Only an empty folder with the recorded identity is removed. */
static int plan_folder_recovery(OHNTFSVolume *view, RecoveryEntry *entries, size_t count)
{
    for (size_t i = count; i-- > 0; ) {
        RecoveryEntry *entry = &entries[i];
        entry->action = 0;
        uint64_t parent = 0;
        OHNTFSItem item;
        int status = resolve_plain_directory(view, entry->folder[0], &parent);
        if (status == ENOENT || status == ENOTDIR || status == ENOTSUP) continue;
        if (!status) status = oh_ntfs_lookup(view, parent, entry->name[0], &item);
        if (status == ENOENT) continue;
        if (status) return recovery_failure(status, "entry-unreadable", i + 1, entry);
        if (item.kind != 2 || item.special || item.inode < FILE_first_user ||
            item.reference != entry->reference[0]) continue;
        /* The engine never lists a folder twice: a repeated record is a
           damaged or forged journal, refused before any write. */
        for (size_t j = 0; j < count; ++j)
            if (j != i && entries[j].reference[0] == entry->reference[0])
                return recovery_failure(EPERM, "overlapping-names", i + 1, entry);
        FolderChildren children = { .entries = entries, .count = count };
        if (oh_ntfs_list(view, item.inode, count_folder_child, &children) ||
            children.occupied) continue;
        entry->inode = item.inode;
        entry->action = 3;
    }
    return 0;
}

/* Resolve all paths in a read-only view, distinguishing absence from I/O
   errors. No action may remove the last name, target a reused record, or
   overlap another record's names (including NTFS case aliases). */
static int plan_recovery(Target *target, RecoveryEntry *entries, size_t count,
                          PendingList *pending)
{
    OHNTFSVolume *view = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &view, &warnings);
    if (status) return status;
    if (warnings) status = EBUSY;
    int folders = count && entries[0].type == 'D'; /* version 3: folders only */
    if (!status && folders) status = plan_folder_recovery(view, entries, count);
    RecoveryName *names = folders ? NULL : calloc(2 * count + 1, sizeof(*names));
    if (!folders && !names) status = ENOMEM;
    for (size_t i = 0; i < count && !status && !folders; ++i) {
        RecoveryEntry *entry = &entries[i];
        OHNTFSItem items[2] = { 0 };
        int present[2] = { 0 };
        for (size_t j = 0; j < 2 && !status; ++j) {
            RecoveryName *name = &names[2 * i + j];
            name->row = i + 1;
            status = resolve_plain_directory(view, entry->folder[j], &name->folder);
            if (!status) status = oh_ntfs_name_key(view, entry->name[j], &name->key, &name->length);
            if (status) {
                recovery_failure(status, "parent-unavailable", i + 1, entry);
                break;
            }
            status = oh_ntfs_lookup(view, name->folder, entry->name[j], &items[j]);
            if (status == ENOENT) { status = 0; continue; }
            if (status) {
                recovery_failure(status, "entry-unreadable", i + 1, entry);
                break;
            }
            present[j] = 1;
            int unsafe = items[j].special || items[j].inode < FILE_first_user ||
                !items[j].hard_link_count || (entry->type == 'R' && items[j].kind != 1);
            int restored_old = entry->type == 'R' && j == 1 &&
                items[j].reference == entry->reference[0];
            int stale = entry->reference[j] && items[j].reference != entry->reference[j] && !restored_old;
            if (unsafe) status = recovery_failure(EPERM, "unsafe-entry", i + 1, entry);
            else if (stale) status = recovery_failure(ESTALE, "identity-mismatch", i + 1, entry);
        }
        if (status) break;
        if (!present[0] && !present[1]) {
            status = recovery_failure(ENOENT, "both-names-missing", i + 1, entry);
            break;
        }
        if (entry->digest && present[1] && items[1].reference == entry->reference[1]) {
            status = verify_recovered_file(view, &items[1], entry->digest);
            if (status) {
                recovery_failure(status, "content-unverified", i + 1, entry);
                break;
            }
        }
        int same = present[0] && present[1] && items[0].reference == items[1].reference;
        if (present[0] && present[1]) {
            if (same) {
                if (items[0].hard_link_count < 2 || items[1].hard_link_count < 2)
                    status = recovery_failure(EPERM, "link-count-invalid", i + 1, entry);
            } else if (entry->type != 'R' || !entry->reference[0]) {
                status = recovery_failure(EPERM, "different-files", i + 1, entry);
            }
            entry->action = 1;
        } else if (present[0] && entry->type != 'L') {
            entry->action = 2;
        }
        if (entry->type == 'C' && !*entry->folder[0]) {
            for (size_t j = 0; j < pending->count; ++j)
                if (!strcmp(pending->entries[j].name, entry->name[0]))
                    pending->entries[j].journaled = 1;
        }
    }
    if (!status && !folders) {
        qsort(names, 2 * count, sizeof(*names), compare_recovery_names);
        for (size_t i = 1; i < 2 * count; ++i)
            if (!compare_recovery_names(&names[i - 1], &names[i])) {
                size_t row = names[i].row;
                status = recovery_failure(EPERM, "overlapping-names", row, &entries[row - 1]);
                break;
            }
    }
    for (size_t i = 0; i < pending->count && !status; ++i)
        if (pending->entries[i].directory && !pending->entries[i].journaled) status = EPERM;
    for (size_t i = 0; names && i < 2 * count; ++i) free(names[i].key);
    free(names);
    oh_ntfs_close(view);
    return target->io_failed ? EIO : status;
}

static int apply_journal(ntfs_volume *volume, const RecoveryEntry *entries, size_t count)
{
    int folders = count && entries[0].type == 'D';
    for (size_t n = 0; n < count; ++n) {
        /* Folders are listed parents first and removed children first. */
        const RecoveryEntry *entry = &entries[folders ? count - 1 - n : n];
        int result = entry->action == 1 || entry->action == 3 ?
            unlink_name(volume, entry->folder[0], entry->name[0]) :
            entry->action == 2 ? rename_entry(volume, entry->folder[0], entry->name[0], entry->name[1], NULL) : 0;
        if (result) return -1;
        #ifdef OPENHDD_TESTING
        if (getenv("OPENHDD_TEST_ABORT_RECOVERY_AFTER_ENTRY")) {
            ntfs_umount(volume, FALSE);
            _exit(86);
        }
        #endif
    }
    return 0;
}

/* Shared read-only planning for diagnostics and actual recovery. */
static int prepare_recovery(Target *target, PendingList *list, char **journal,
                             RecoveryEntry **entries, size_t *entry_count)
{
    OHNTFSVolume *view = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &view, &warnings);
    if (!status) {
        status = warnings ? EBUSY : oh_ntfs_list(view, FILE_root, collect_pending, list);
        oh_ntfs_close(view);
    }
    if (!status && target->io_failed) status = EIO;
    if (!status && list->journal) {
        status = read_journal(target, journal);
        if (!status) {
            *entries = calloc(MAX_ITEMS, sizeof(**entries));
            status = *entries ? parse_journal(*journal, *entries, entry_count) : ENOMEM;
        }
    }
    if (!status && (list->count || list->journal))
        status = plan_recovery(target, *entries, *entry_count, list);
    if (status) {
        if (!*recovery_error)
            recovery_failure(status, warnings ? "volume-needs-check" : "journal-or-temporary-unreadable", 0, NULL);
        note_error("recovery journal or temporary entries are invalid or ambiguous; preserved without changes");
    }
    return status;
}

int oh_inspect_recovery(int fd, uint64_t size, int is_device)
{
    last_error[0] = recovery_error[0] = 0;
    Target target = { .fd = fd, .size = size, .is_device = is_device,
                      .align = device_alignment(fd) };
    if (!target.align) return EIO;
    PendingList list = { 0 };
    char *journal = NULL;
    RecoveryEntry *entries = NULL;
    size_t count = 0;
    int status = prepare_recovery(&target, &list, &journal, &entries, &count);
    free(entries);
    free(journal);
    free(list.entries);
    return status;
}

/* Only a clean volume can be recovered. Validate the entire journal and
   pending list before marking it dirty; keep all artifacts on ambiguity. */
static int remove_pending(Target *target, size_t *removed, int *failure_stage)
{
    PendingList list = { 0 };
    char *journal = NULL;
    RecoveryEntry *entries = NULL;
    size_t entry_count = 0;
    int status = prepare_recovery(target, &list, &journal, &entries, &entry_count);
    if (status) goto out;
    if (!list.count && !list.journal) goto out;
    if (failure_stage) *failure_stage = 2;
    if (set_volume_dirty(target, 1)) { status = phase_error(target); goto out; }
    ntfs_volume *volume = mount_rw(target);
    if (!volume) { status = phase_error(target); goto out; }
    int result = apply_journal(volume, entries, entry_count);
    for (size_t i = 0; i < list.count && !result; ++i) {
        PendingEntry *pending = &list.entries[i];
        if (pending->journaled) continue; /* already handled, including directories */
        result = unlink_name(volume, "", pending->name);
    }
    int failure = result ? errno : 0;
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    /* Keep the journal until every recovery action is durable. */
    if (!result && journal && remove_journal(target)) result = -1;
    if (result) { if (failure) errno = failure; status = phase_error(target); goto out; }
    if (set_volume_dirty(target, 0)) { status = phase_error(target); goto out; }
    *removed = list.count + (journal ? 1 : 0);
out:
    free(entries);
    free(journal);
    free(list.entries);
    return status;
}

/* A cancelled batch is undone while nothing is published yet: the folders
   it created (still empty, files wait in the root) and the temporaries are
   removed, then the mark is cleared. */
static int roll_back(Target *target, const char *const *directories,
                     const unsigned char *missing, size_t count)
{
    ntfs_volume *volume = mount_rw(target);
    if (!volume) return -1;
    int result = 0;
    for (size_t i = count; i-- > 0 && !result; ) {
        if (!missing[i]) continue;
        char parent[4097];
        const char *leaf = NULL;
        result = split_path(directories[i], parent, sizeof(parent), &leaf) ? -1 :
            unlink_name(volume, parent, leaf);
    }
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(target)) result = -1;
    if (result) return -1;
    size_t removed = 0;
    int status = remove_pending(target, &removed, NULL);
    if (status) { errno = status; return -1; }
    if (target->own_dirty && set_volume_dirty(target, 0)) return -1;
    uint32_t warnings = 0;
    status = volume_scan(target, NULL, &warnings);
    if (status || warnings) { errno = status ? status : EIO; return -1; }
    return 0;
}

typedef struct {
    char *key;
    size_t index; /* items first, then folders to create */
} NameKey;

static int compare_keys(const void *a, const void *b)
{
    return strcmp(((const NameKey *)a)->key, ((const NameKey *)b)->key);
}

static char *entry_key(const char *folder, const char *name)
{
    size_t length = strlen(folder) + strlen(name) + 2;
    char *joined = malloc(length);
    if (!joined) return NULL;
    snprintf(joined, length, "%s/%s", folder, name);
    char *key = fold_key(joined);
    free(joined);
    return key;
}

/* Two entries in one folder whose names differ only in case, among the new
   files and the folders to create. */
static int duplicate_names(const char *const *directories,
                           const unsigned char *missing, size_t directory_count,
                           const OHCopyItem *items, size_t count,
                           size_t *failed_index)
{
    NameKey *keys = calloc(count + directory_count + 1, sizeof(*keys));
    size_t used = 0;
    int status = keys ? 0 : ENOMEM;
    for (size_t i = 0; i < count && !status; ++i) {
        keys[used].key = entry_key(item_directory(&items[i]), items[i].destination_name);
        keys[used].index = i;
        if (!keys[used++].key) status = ENOMEM;
    }
    for (size_t i = 0; i < directory_count && !status; ++i) {
        if (!missing[i]) continue;
        char parent[4097];
        const char *leaf = NULL;
        if (split_path(directories[i], parent, sizeof(parent), &leaf) ||
            !oh_ntfs_valid_new_name(leaf)) { status = EINVAL; break; }
        keys[used].key = entry_key(parent, leaf);
        keys[used].index = count + i;
        if (!keys[used++].key) status = ENOMEM;
    }
    if (!status) {
        qsort(keys, used, sizeof(*keys), compare_keys);
        for (size_t i = 1; i < used; ++i)
            if (!strcmp(keys[i - 1].key, keys[i].key)) {
                size_t index = keys[i].index < keys[i - 1].index ? keys[i - 1].index : keys[i].index;
                *failed_index = index < count ? index : index - count;
                if (index >= count)
                    note_error("folder %zu clashes with another entry", index - count + 1);
                status = EEXIST;
                break;
            }
    }
    for (size_t i = 0; keys && i < used; ++i) free(keys[i].key);
    free(keys);
    return status;
}

/* Read-only planning in one view: which folders must be created, where
   every file goes, and which existing files are replaced. */
static int plan_copy(Target *target, const char *const *directories,
                     unsigned char *missing, size_t directory_count,
                     const OHCopyItem *items, Staged *staged, size_t count,
                     size_t *failed_index)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    if (warnings) status = EBUSY;
    for (size_t i = 0; i < directory_count && !status; ++i) {
        *failed_index = i;
        uint64_t inode = 0;
        status = resolve_plain_directory(volume, directories[i], &inode);
        if (!status) { missing[i] = 0; continue; }
        if (status != ENOENT) {
            if (status == ENOTDIR) status = EEXIST; /* a file is in the way */
            note_error("folder \"%s\" cannot be used", directories[i]);
            break;
        }
        char parent[4097];
        const char *leaf = NULL;
        if (split_path(directories[i], parent, sizeof(parent), &leaf) ||
            !oh_ntfs_valid_new_name(leaf)) { status = EINVAL; break; }
        status = 0;
        int parent_planned = 0;
        for (size_t j = 0; j < i && !parent_planned; ++j)
            parent_planned = missing[j] && !strcmp(directories[j], parent);
        if (!parent_planned) {
            status = resolve_plain_directory(volume, parent, &inode);
            if (status) { note_error("parent of folder \"%s\" not found", directories[i]); break; }
            int exists = 0;
            status = oh_ntfs_name_exists_nocase(volume, inode, leaf, &exists);
            if (!status && exists) {
                status = EEXIST;
                note_error("folder \"%s\": a file with that name exists", directories[i]);
            }
        }
        missing[i] = 1;
    }
    FolderCache cache = { 0 };
    FolderIndex index = { 0 };
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        const char *folder = item_directory(&items[i]);
        int planned = 0;
        for (size_t j = 0; j < directory_count && !planned; ++j)
            planned = missing[j] && !strcmp(directories[j], folder);
        staged[i].directory_inode = 0;
        if (planned) continue; /* a new folder: only the batch itself can clash */
        status = item_folder(volume, &cache, &items[i], &staged[i].directory_inode);
        if (!status) status = index_folder(volume, &index, staged[i].directory_inode);
        const IndexEntry *existing = NULL;
        int exact = 0;
        if (!status)
            status = index_find(volume, &index, items[i].destination_name, &existing, &exact);
        if (status || !existing) continue;
        if (!items[i].replace) { status = EEXIST; break; }
        if (!exact) {
            note_error("the existing name differs in letter case");
            status = EEXIST;
            break;
        }
        if (existing->directory) {
            note_error("a folder cannot be replaced by a file");
            status = EISDIR;
            break;
        }
        OHNTFSItem old_item;
        status = oh_ntfs_stat(volume, existing->inode, &old_item);
        if (status) break;
        if (old_item.special) { status = ENOTSUP; break; }
        if (old_item.kind != 1) { status = EISDIR; break; }
        staged[i].replacing = 1;
        staged[i].old_inode = existing->inode;
        staged[i].old_reference = old_item.reference;
        make_temporary_name(staged[i].old, old_prefix);
    }
    index_free(&index);
    oh_ntfs_close(volume);
    if (!status)
        status = duplicate_names(directories, missing, directory_count, items,
                                 count, failed_index);
    return target->io_failed ? EIO : status;
}

uint64_t oh_copy_work_units(uint64_t bytes, size_t files, size_t directories)
{
    /* write + one read-back + publish/complete bookkeeping */
    return 2 * bytes + (uint64_t)files * UNIT_OVERHEAD +
        (uint64_t)directories * (UNIT_OVERHEAD / 8);
}

int oh_copy_files(int target_fd, uint64_t target_size, int is_device,
                  const char *const *directories, size_t directory_count,
                  const OHCopyItem *items, size_t count,
                  OHCopyProgress progress, void *progress_context,
                  size_t *failed_index, int *failure_stage,
                  uint32_t *safety_warnings, size_t *removed_pending)
{
    if (!failure_stage || !safety_warnings || !failed_index) return EINVAL;
    last_error[0] = recovery_error[0] = 0;
    *failure_stage = 1;
    *failed_index = 0;
    *safety_warnings = 0;
    if (removed_pending) *removed_pending = 0;
    if ((!items && count) || count > MAX_ITEMS || (!directories && directory_count) ||
        directory_count > MAX_DIRECTORIES || !(count + directory_count)) return EINVAL;
    struct stat target_info;
    if (fstat(target_fd, &target_info)) return EINVAL;
    if (is_device ? !(S_ISBLK(target_info.st_mode) || S_ISCHR(target_info.st_mode)) :
        !S_ISREG(target_info.st_mode)) return EPERM;
    if (target_size < 4096 || target_size > INT64_MAX) return EINVAL;
    for (size_t i = 0; i < directory_count; ++i) {
        *failed_index = i;
        const char *path = directories[i];
        if (!path || !*path || path[0] == '/' || !oh_ntfs_valid_directory_path(path)) {
            note_error("invalid folder %zu", i + 1);
            return EINVAL;
        }
        if (protected_path(path)) return EACCES;
    }
    quiet_ntfs_log();

    struct stat *sources = calloc(count + 1, sizeof(*sources));
    Staged *staged = calloc(count + 1, sizeof(*staged));
    unsigned char *missing = calloc(directory_count + 1, 1);
    unsigned char *buffer = NULL;
    int status = sources && staged && missing ? 0 : ENOMEM;
    uint64_t total = 0;
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        const char *folder = item_directory(&items[i]);
        if (!oh_ntfs_valid_new_name(items[i].destination_name) ||
            folder[0] == '/' || (*folder && !oh_ntfs_valid_directory_path(folder)))
            status = EINVAL;
        else if ((*folder && protected_path(folder)) ||
                 (!*folder && protected_path(items[i].destination_name)))
            status = EACCES;
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
                      .is_device = is_device,
                      .align = device_alignment(target_fd) };
    if (!target.align) { status = EIO; goto out; }
    Work work = { .callback = progress, .context = progress_context,
                  .count = count,
                  .total = oh_copy_work_units(total, count, directory_count) };
    work_report(&work, OH_PHASE_PREPARE, 0);
    uint64_t free_bytes = 0;
    *failed_index = 0;
    status = volume_scan(&target, &free_bytes, safety_warnings);
    if (status == EINPROGRESS && !*safety_warnings && removed_pending) {
        size_t removed = 0;
        status = remove_pending(&target, &removed, failure_stage);
        if (status) goto out;
        *removed_pending = removed;
        *failure_stage = 1;
        status = volume_scan(&target, &free_bytes, safety_warnings);
    }
    if (status) goto out;
    status = plan_copy(&target, directories, missing, directory_count, items,
                       staged, count, failed_index);
    if (status) goto out;
    *failed_index = 0;
    size_t replacing = 0, creating = 0;
    for (size_t i = 0; i < count; ++i) replacing += staged[i].replacing != 0;
    for (size_t i = 0; i < directory_count; ++i) creating += missing[i] != 0;
    uint64_t reserve = total / 100;
    if (reserve < 16 * 1024 * 1024) reserve = 16 * 1024 * 1024;
    /* Per-entry metadata overhead: MFT record and index growth. */
    reserve += (uint64_t)(count + creating) * 64 * 1024;
    if (free_bytes < total || free_bytes - total < reserve) {
        status = ENOSPC;
        goto out;
    }
    if (posix_memalign((void **)&buffer, 4096, IO_CHUNK)) {
        status = ENOMEM;
        goto out;
    }
    for (size_t i = 0; i < count; ++i) make_pending_name(staged[i].pending);

    #ifdef OPENHDD_TESTING
    abort_at_stage(2);
    #endif
    if (cancel_flag) { status = ECANCELED; goto out; }
    *failure_stage = 2;
    if (set_volume_dirty(&target, 1)) { status = phase_error(&target); goto out; }
    if (creating && create_directories(&target, directories, missing, directory_count,
                                       &work, failed_index)) {
        status = phase_error(&target);
        goto out;
    }
    int folder_journal = creating ?
        write_folder_journal(&target, directories, missing, directory_count) : 0;
    if (folder_journal < 0) { status = phase_error(&target); goto out; }
    if (count && write_all(&target, items, sources, staged, count, buffer, &work,
                           failed_index)) {
        status = phase_error(&target);
        goto cancelled;
    }

    *failure_stage = 3;
    #ifdef OPENHDD_TESTING
    abort_at_stage(3);
    #endif
    status = verify_all(&target, items, staged, count, buffer, &work, failed_index);
cancelled:
    if (status && cancel_flag && !target.io_failed && status != ESTALE) {
        /* Nothing is published yet: undo the batch and leave it clean. */
        if (roll_back(&target, directories, missing, directory_count)) {
            /* Still marked: Windows must check it, as after any failure. */
            status = phase_error(&target);
            if (status == ECANCELED) status = EIO;
        } else {
            status = ECANCELED;
            *failure_stage = 1;
        }
        goto out;
    }
    if (status) goto out;

    *failure_stage = 4;
    #ifdef OPENHDD_TESTING
    abort_at_stage(4);
    if (getenv("OPENHDD_TEST_FAIL_BEFORE_PUBLISH")) { status = EIO; goto out; }
    #endif
    /* From here on the new folders belong to the result: drop their
       journal before the replacement journal or the first publication. */
    if (folder_journal > 0 && remove_journal(&target)) {
        status = phase_error(&target);
        goto out;
    }
    if (replacing && write_journal(&target, items, staged, count)) {
        status = phase_error(&target);
        goto out;
    }
    if (count && publish_all(&target, items, staged, count, &work, failed_index)) {
        status = phase_error(&target);
        goto out;
    }

    *failure_stage = 5;
    #ifdef OPENHDD_TESTING
    abort_at_stage(5);
    #endif
    status = check_names(&target, items, staged, count, 1, failed_index);
    if (status) goto out;
    if (count && complete_all(&target, items, staged, count, &work, failed_index)) {
        status = phase_error(&target);
        goto out;
    }
    status = check_names(&target, items, staged, count, 0, failed_index);
    if (status) goto out;
    if (replacing && remove_journal(&target)) { status = phase_error(&target); goto out; }

    *failure_stage = 6;
    #ifdef OPENHDD_TESTING
    abort_at_stage(6);
    #endif
    if (set_volume_dirty(&target, 0)) { status = phase_error(&target); goto out; }
    uint32_t final_warnings = 0;
    status = volume_scan(&target, NULL, &final_warnings);
    if (status || final_warnings) { status = status ? status : EIO; goto out; }
    *failure_stage = 0;
    work.done = work.total;
    work_report(&work, OH_PHASE_FINISH, count ? count - 1 : 0);
    #ifdef OPENHDD_TESTING
    abort_at_stage(0);
    if (getenv("OPENHDD_TEST_REPORT_WRITES"))
        fprintf(stderr, "writes=%llu\n", (unsigned long long)target.write_calls);
    #endif
out:
    free(buffer);
    free(missing);
    free(staged);
    free(sources);
    return status;
}

int oh_copy_new_files(int target_fd, uint64_t target_size, int is_device,
                      const char *directory_path,
                      const OHCopyItem *items, size_t count,
                      OHCopyProgress progress, void *progress_context,
                      size_t *failed_index, int *failure_stage,
                      uint32_t *safety_warnings, size_t *removed_pending)
{
    if (!failure_stage || !safety_warnings || !failed_index) return EINVAL;
    if (!items || !count || count > MAX_ITEMS) return EINVAL;
    if (directory_path && (!*directory_path || !strcmp(directory_path, "/")))
        directory_path = NULL;
    if (!oh_ntfs_valid_directory_path(directory_path)) return EINVAL;
    OHCopyItem *copy = calloc(count, sizeof(*copy));
    if (!copy) return ENOMEM;
    for (size_t i = 0; i < count; ++i) {
        copy[i] = items[i];
        copy[i].directory = directory_path;
        copy[i].replace = 0;
    }
    int status = oh_copy_files(target_fd, target_size, is_device, NULL, 0, copy,
                               count, progress, progress_context, failed_index,
                               failure_stage, safety_warnings, removed_pending);
    free(copy);
    return status;
}

/* ------------------------------------------------------------------------ */
/* v2 edits: delete, rename, new folder                                     */
/* ------------------------------------------------------------------------ */

enum { MAX_DELETE_ENTRIES = 1000000 };

/* Splits "a/b/c" into "a/b" and "c". The parent is "" for the root. */
static int split_path(const char *path, char *parent, size_t parent_size,
                      const char **leaf)
{
    const char *slash = strrchr(path, '/');
    size_t length = slash ? (size_t)(slash - path) : 0;
    if (length >= parent_size) return -1;
    memcpy(parent, path, length);
    parent[length] = 0;
    *leaf = slash ? slash + 1 : path;
    return **leaf ? 0 : -1;
}

/* Names that belong to NTFS or Windows itself, and OpenHDD's temporaries. */
static int protected_path(const char *path)
{
    const char *first_end = strchr(path, '/');
    size_t first = first_end ? (size_t)(first_end - path) : strlen(path);
    if (first && path[0] == '$') return 1;
    if (first == 25 && !strncasecmp(path, "System Volume Information", 25)) return 1;
    for (const char *part = path; part; part = strchr(part, '/')) {
        if (*part == '/') ++part;
        if (!strncasecmp(part, ".OpenHDD-", 9)) return 1;
    }
    return 0;
}

typedef struct {
    uint64_t count;
    uint64_t *directories;
    size_t pending, capacity;
    int error;
} TreeCount;

/* The bridge holds its lock during a listing, so subdirectories are queued
   and visited after the listing returns, never from inside the callback. */
static int count_entry(void *opaque, const char *name, const OHNTFSItem *item)
{
    (void)name;
    TreeCount *walk = opaque;
    if (item->special) return ENOTSUP; /* never follow junctions or links */
    if (++walk->count > MAX_DELETE_ENTRIES) return EFBIG;
    if (item->kind != 2) return 0;
    if (walk->pending == walk->capacity) {
        size_t capacity = walk->capacity ? walk->capacity * 2 : 64;
        uint64_t *grown = realloc(walk->directories, capacity * sizeof(*grown));
        if (!grown) return ENOMEM;
        walk->directories = grown;
        walk->capacity = capacity;
    }
    walk->directories[walk->pending++] = item->inode;
    return 0;
}

static int count_tree(OHNTFSVolume *volume, uint64_t root, uint64_t *count)
{
    TreeCount walk = { .count = 0 };
    int status = 0;
    uint64_t next = root;
    for (;;) {
        status = oh_ntfs_list(volume, next, count_entry, &walk);
        if (status || !walk.pending) break;
        next = walk.directories[--walk.pending];
    }
    free(walk.directories);
    *count += walk.count;
    return status;
}

typedef struct {
    ntfschar *name;
    int length;
    uint64_t mref;
    int directory;
} Child;

typedef struct {
    Child *items;
    size_t count, capacity;
    int error;
} ChildList;

static int collect_child(void *opaque, const ntfschar *name, int name_length,
                         int name_type, s64 position, MFT_REF mref, unsigned type)
{
    (void)position;
    ChildList *list = opaque;
    if (name_type == FILE_NAME_DOS) return 0;
    if ((name_length == 1 && le16_to_cpu(name[0]) == '.') ||
        (name_length == 2 && le16_to_cpu(name[0]) == '.' && le16_to_cpu(name[1]) == '.'))
        return 0;
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 64;
        Child *grown = realloc(list->items, capacity * sizeof(*grown));
        if (!grown) { list->error = ENOMEM; return 1; }
        list->items = grown;
        list->capacity = capacity;
    }
    ntfschar *copy = malloc((size_t)name_length * sizeof(ntfschar));
    if (!copy) { list->error = ENOMEM; return 1; }
    memcpy(copy, name, (size_t)name_length * sizeof(ntfschar));
    list->items[list->count++] = (Child){ copy, name_length, MREF(mref),
                                          type == NTFS_DT_DIR };
    return 0;
}

static void free_children(ChildList *list)
{
    for (size_t i = 0; i < list->count; ++i) free(list->items[i].name);
    free(list->items);
}

/* Removes one directory entry (and the whole subtree below a directory),
   children first. ntfs_delete consumes both inodes it is given. */
static int delete_entry(ntfs_volume *volume, uint64_t parent, const ntfschar *name,
                        int length, uint64_t mref, int directory, Work *work,
                        size_t index)
{
    if (directory) {
        ChildList list = { 0 };
        ntfs_inode *dir = ntfs_inode_open(volume, mref);
        if (!dir) return -1;
        s64 position = 0;
        int result = ntfs_readdir(dir, &position, &list, collect_child);
        if (ntfs_inode_close(dir) || result || list.error) {
            free_children(&list);
            errno = list.error ? list.error : EIO;
            return -1;
        }
        for (size_t i = 0; i < list.count; ++i) {
            if (delete_entry(volume, mref, list.items[i].name, list.items[i].length,
                             list.items[i].mref, list.items[i].directory, work, index)) {
                free_children(&list);
                return -1;
            }
        }
        free_children(&list);
    }
    ntfs_inode *dir_ni = ntfs_inode_open(volume, parent);
    ntfs_inode *ni = ntfs_inode_open(volume, mref);
    if (!dir_ni || !ni || (ni->flags & (FILE_ATTR_REPARSE_POINT | FILE_ATTR_ENCRYPTED))) {
        if (ni) ntfs_inode_close(ni);
        if (dir_ni) ntfs_inode_close(dir_ni);
        errno = ni ? ENOTSUP : EIO;
        return -1;
    }
    char *utf8 = NULL;
    if (ntfs_ucstombs(name, length, &utf8, 0) < 0) utf8 = NULL;
    int result = ntfs_delete(volume, utf8, ni, dir_ni, name, (u8)length);
    free(utf8);
    work_advance(work, OH_PHASE_WRITE, index, 1);
    return result;
}

static ntfs_inode *lookup_child(ntfs_volume *volume, ntfs_inode *directory,
                                const char *name)
{
    return ntfs_pathname_to_inode(volume, directory, name);
}

static int link_name(ntfs_inode *ni, ntfs_inode *directory, const char *name)
{
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    int result = length > 0 && length <= 255 ?
        ntfs_link(ni, directory, wide, (u8)length) : -1;
    free(wide);
    return result;
}

static int unlink_name(ntfs_volume *volume, const char *parent_path,
                       const char *name)
{
    ntfs_inode *directory = open_directory(volume, parent_path);
    ntfs_inode *ni = directory ? lookup_child(volume, directory, name) : NULL;
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    if (!directory || !ni || length <= 0 || length > 255) {
        if (ni) ntfs_inode_close(ni);
        if (directory) ntfs_inode_close(directory);
        free(wide);
        errno = EIO;
        return -1;
    }
    int result = ntfs_delete(volume, name, ni, directory, wide, (u8)length);
    free(wide);
    return result;
}

#ifdef OPENHDD_TESTING
/* Emulates a crash while an entry has both its old and its new name. */
static void abort_with_two_names(ntfs_volume *volume)
{
    if (!getenv("OPENHDD_TEST_ABORT_WITH_TWO_NAMES")) return;
    ntfs_umount(volume, FALSE);
    _exit(86);
}
#endif

/* Rename inside one directory: add the new name, then remove the old one.
   A change of letter case alone goes through a temporary name (given by the
   caller when it is journaled), because NTFS indexes names without regard
   to case. */
static int rename_entry(ntfs_volume *volume, const char *parent_path,
                        const char *old_name, const char *new_name,
                        const char *temporary)
{
    int case_only = same_name_ignoring_case(old_name, new_name);
    char generated[PENDING_LENGTH + 1];
    if (!temporary) {
        make_pending_name(generated);
        temporary = generated;
    }
    const char *first = case_only ? temporary : new_name;
    ntfs_inode *directory = open_directory(volume, parent_path);
    ntfs_inode *ni = directory ? lookup_child(volume, directory, old_name) : NULL;
    int result = ni ? link_name(ni, directory, first) : -1;
    if (ni) ntfs_inode_close(ni);
    if (directory) ntfs_inode_close(directory);
    #ifdef OPENHDD_TESTING
    if (!result) abort_with_two_names(volume);
    #endif
    if (result || unlink_name(volume, parent_path, old_name)) return -1;
    if (!case_only) return 0;
    #ifdef OPENHDD_TESTING
    if (getenv("OPENHDD_TEST_ABORT_AFTER_CASE_UNLINK")) {
        ntfs_umount(volume, FALSE);
        _exit(86);
    }
    #endif
    directory = open_directory(volume, parent_path);
    ni = directory ? lookup_child(volume, directory, temporary) : NULL;
    result = ni ? link_name(ni, directory, new_name) : -1;
    if (ni) ntfs_inode_close(ni);
    if (directory) ntfs_inode_close(directory);
    if (result) return -1;
    return unlink_name(volume, parent_path, temporary);
}

static int make_directory(ntfs_volume *volume, const char *parent_path,
                          const char *name)
{
    ntfs_inode *directory = open_directory(volume, parent_path);
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    ntfs_inode *created = directory && length > 0 && length <= 255 ?
        ntfs_create(directory, const_cpu_to_le32(0), wide, (u8)length, S_IFDIR) : NULL;
    free(wide);
    int result = created ? 0 : -1;
    if (created && ntfs_inode_close(created)) result = -1;
    if (directory && ntfs_inode_close(directory)) result = -1;
    return result;
}

/* Move to another folder, keeping the name: add the name there, then
   remove it here. NTFS keeps the parent in each name, so a folder moves
   with everything below it. */
static int move_entry(ntfs_volume *volume, const char *parent_path,
                      const char *name, const char *destination_path)
{
    ntfs_inode *directory = open_directory(volume, parent_path);
    ntfs_inode *destination = open_directory(volume, destination_path);
    ntfs_inode *ni = directory ? lookup_child(volume, directory, name) : NULL;
    int result = ni && destination ? link_name(ni, destination, name) : -1;
    if (ni) ntfs_inode_close(ni);
    if (destination) ntfs_inode_close(destination);
    if (directory) ntfs_inode_close(directory);
    if (result) return -1;
    #ifdef OPENHDD_TESTING
    abort_with_two_names(volume);
    #endif
    return unlink_name(volume, parent_path, name);
}

/* True when `path` is `ancestor` or lies below it, ignoring case. */
static int path_within(const char *path, const char *ancestor)
{
    char *a = fold_key(path), *b = fold_key(ancestor);
    size_t length = b ? strlen(b) : 0;
    int within = !a || !b || (!strncmp(a, b, length) &&
                              (a[length] == 0 || a[length] == '/'));
    free(a);
    free(b);
    return within; /* fail closed */
}

typedef struct {
    char parent[1025];
    const char *leaf;
    uint64_t parent_inode;
    uint64_t inode;
    uint64_t destination_inode;
    uint64_t reference;
    int directory;
    char temporary[PENDING_LENGTH + 1]; /* case-only rename */
} EditPlan;

/* Read-only checks for every edit before the volume is marked. */
static int plan_edits(Target *target, const OHEdit *edits, EditPlan *plans,
                      size_t count, uint64_t *units, size_t *failed_index)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    if (warnings) status = EBUSY;
    *units = 0;
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        EditPlan *plan = &plans[i];
        const OHEdit *edit = &edits[i];
        if (edit->kind == OH_EDIT_MKDIR) {
            snprintf(plan->parent, sizeof(plan->parent), "%s",
                     edit->path ? edit->path : "");
            plan->leaf = edit->name;
            status = oh_ntfs_resolve_directory(volume, plan->parent, &plan->parent_inode);
            if (status) break;
        } else {
            if (split_path(edit->path, plan->parent, sizeof(plan->parent),
                           &plan->leaf)) { status = EINVAL; break; }
            if (edit->kind != OH_EDIT_DELETE &&
                (!oh_ntfs_valid_new_name(plan->leaf) || !recovery_directory(plan->parent) ||
                 (edit->kind == OH_EDIT_MOVE && !recovery_directory(edit->name)))) {
                status = EINVAL;
                break;
            }
            status = oh_ntfs_resolve_directory(volume, plan->parent, &plan->parent_inode);
            if (status) break;
            OHNTFSItem item;
            status = oh_ntfs_lookup(volume, plan->parent_inode, plan->leaf, &item);
            if (status) break;
            if (item.special) { status = ENOTSUP; break; }
            plan->inode = item.inode;
            plan->reference = item.reference;
            plan->directory = item.kind == 2;
            if (edit->kind == OH_EDIT_MOVE) {
                status = resolve_plain_directory(volume, edit->name,
                                                 &plan->destination_inode);
                if (status) { note_error("destination folder not usable"); break; }
                if (plan->destination_inode == plan->parent_inode) {
                    note_error("item %zu is already in that folder", i + 1);
                    status = EINVAL;
                    break;
                }
                if (plan->directory && path_within(edit->name, edit->path)) {
                    note_error("a folder cannot be moved into itself");
                    status = EINVAL;
                    break;
                }
                int exists = 0;
                status = oh_ntfs_name_exists_nocase(volume, plan->destination_inode,
                                                    plan->leaf, &exists);
                if (!status && exists) status = EEXIST;
                if (status) break;
                /* Items of one request must not land on the same name or
                   contain each other: later paths would no longer hold. */
                for (size_t j = 0; j < i && !status; ++j) {
                    if (edits[j].kind != OH_EDIT_MOVE) continue;
                    if ((plans[j].destination_inode == plan->destination_inode &&
                         same_name_ignoring_case(plans[j].leaf, plan->leaf)))
                        status = EEXIST;
                    else if (path_within(edit->path, edits[j].path) ||
                             path_within(edits[j].path, edit->path)) {
                        note_error("items %zu and %zu overlap", j + 1, i + 1);
                        status = EINVAL;
                    }
                }
                if (status) break;
                *units += 1;
                continue;
            }
            if (edit->kind == OH_EDIT_DELETE) {
                uint64_t entries = 1;
                if (plan->directory) status = count_tree(volume, item.inode, &entries);
                if (status) break;
                *units += entries;
                continue;
            }
        }
        /* Rename and new folder: the new name must be free, except for a
           change of case of the same entry. */
        const char *new_name = edit->name;
        int exists = 0;
        status = oh_ntfs_name_exists_nocase(volume, plan->parent_inode, new_name, &exists);
        if (status) break;
        if (exists && !(edit->kind == OH_EDIT_RENAME &&
                        same_name_ignoring_case(plan->leaf, new_name))) {
            status = EEXIST;
            break;
        }
        if (edit->kind == OH_EDIT_RENAME && !strcmp(plan->leaf, new_name)) {
            status = EINVAL;
            break;
        }
        *units += 1;
    }
    oh_ntfs_close(volume);
    return target->io_failed ? EIO : status;
}

static int check_edits(Target *target, const OHEdit *edits, const EditPlan *plans,
                       size_t count, size_t *failed_index)
{
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int status = readonly_open(target, &volume, &warnings);
    if (status) return status;
    if (warnings) status = EBUSY;
    for (size_t i = 0; i < count && !status; ++i) {
        *failed_index = i;
        OHNTFSItem item;
        int found;
        switch (edits[i].kind) {
        case OH_EDIT_DELETE:
            found = oh_ntfs_lookup(volume, plans[i].parent_inode, plans[i].leaf, &item);
            if (found != ENOENT) status = found ? found : EIO;
            break;
        case OH_EDIT_MOVE:
            if (oh_ntfs_lookup(volume, plans[i].destination_inode, plans[i].leaf, &item) ||
                item.inode != plans[i].inode) { status = EIO; break; }
            found = oh_ntfs_lookup(volume, plans[i].parent_inode, plans[i].leaf, &item);
            if (found != ENOENT) status = EIO;
            break;
        case OH_EDIT_RENAME:
            if (oh_ntfs_lookup(volume, plans[i].parent_inode, edits[i].name, &item) ||
                item.inode != plans[i].inode) { status = EIO; break; }
            if (!same_name_ignoring_case(plans[i].leaf, edits[i].name)) {
                found = oh_ntfs_lookup(volume, plans[i].parent_inode, plans[i].leaf, &item);
                if (found != ENOENT) status = EIO;
            }
            break;
        default:
            if (oh_ntfs_lookup(volume, plans[i].parent_inode, edits[i].name, &item) ||
                item.kind != 2) status = EIO;
        }
    }
    oh_ntfs_close(volume);
    return target->io_failed ? EIO : status;
}

/* Moves and renames are journaled: an interruption can leave an entry with
   both names, which the next session settles. */
static int write_edit_journal(Target *target, const OHEdit *edits, EditPlan *plans,
                              size_t count, int *journaled)
{
    size_t length = 0;
    for (size_t i = 0; i < count; ++i) {
        if (edits[i].kind != OH_EDIT_RENAME && edits[i].kind != OH_EDIT_MOVE) continue;
        make_pending_name(plans[i].temporary);
        length += 2 * strlen(plans[i].parent) + strlen(edits[i].name) +
            2 * strlen(plans[i].leaf) + PENDING_LENGTH + 25;
    }
    *journaled = 0;
    if (!length) return 0;
    if (length > MAX_JOURNAL) return EFBIG;
    char *text = malloc(length + 1);
    if (!text) return ENOMEM;
    size_t used = 0;
    for (size_t i = 0; i < count; ++i) {
        const EditPlan *plan = &plans[i];
        if (edits[i].kind == OH_EDIT_MOVE)
            used += (size_t)snprintf(text + used, length + 1 - used, "L\t%s\t%s\t%s\t%s\t%016llx\n",
                                     plan->parent, plan->leaf, edits[i].name, plan->leaf,
                                     (unsigned long long)plan->reference);
        else if (edits[i].kind == OH_EDIT_RENAME) {
            if (same_name_ignoring_case(plan->leaf, edits[i].name))
                used += (size_t)snprintf(text + used, length + 1 - used, "C\t%s\t%s\t%s\t%016llx\n",
                                         plan->parent, plan->temporary, edits[i].name,
                                         (unsigned long long)plan->reference);
            else
                used += (size_t)snprintf(text + used, length + 1 - used, "L\t%s\t%s\t%s\t%s\t%016llx\n",
                                         plan->parent, plan->leaf, plan->parent, edits[i].name,
                                         (unsigned long long)plan->reference);
        }
    }
    int result = write_journal_text(target, 2, text, used);
    free(text);
    if (result) return phase_error(target);
    *journaled = 1;
    return 0;
}

int oh_edit_volume(int target_fd, uint64_t target_size, int is_device,
                   const OHEdit *edits, size_t count,
                   OHCopyProgress progress, void *progress_context,
                   size_t *failed_index, int *failure_stage,
                   uint32_t *safety_warnings, size_t *removed_pending)
{
    if (!failure_stage || !safety_warnings || !failed_index) return EINVAL;
    last_error[0] = recovery_error[0] = 0;
    *failure_stage = 1;
    *failed_index = 0;
    *safety_warnings = 0;
    if (removed_pending) *removed_pending = 0;
    if (!edits || !count || count > MAX_ITEMS) return EINVAL;
    struct stat target_info;
    if (fstat(target_fd, &target_info)) return EINVAL;
    if (is_device ? !(S_ISBLK(target_info.st_mode) || S_ISCHR(target_info.st_mode)) :
        !S_ISREG(target_info.st_mode)) return EPERM;
    if (target_size < 4096 || target_size > INT64_MAX) return EINVAL;
    for (size_t i = 0; i < count; ++i) {
        *failed_index = i;
        const OHEdit *edit = &edits[i];
        if (edit->kind == OH_EDIT_MKDIR) {
            if (!oh_ntfs_valid_directory_path(edit->path) ||
                !oh_ntfs_valid_new_name(edit->name)) return EINVAL;
            if ((edit->path && protected_path(edit->path)) ||
                ((!edit->path || !*edit->path) && protected_path(edit->name))) return EACCES;
            continue;
        }
        if (edit->kind != OH_EDIT_DELETE && edit->kind != OH_EDIT_RENAME &&
            edit->kind != OH_EDIT_MOVE) return EINVAL;
        if (!edit->path || !*edit->path || edit->path[0] == '/' ||
            !oh_ntfs_valid_directory_path(edit->path)) return EINVAL;
        if (protected_path(edit->path)) return EACCES;
        if (edit->kind == OH_EDIT_RENAME && !oh_ntfs_valid_new_name(edit->name))
            return EINVAL;
        if (edit->kind == OH_EDIT_MOVE) {
            if (!edit->name || edit->name[0] == '/' ||
                !oh_ntfs_valid_directory_path(edit->name)) return EINVAL;
            if (*edit->name && protected_path(edit->name)) return EACCES;
        }
    }
    quiet_ntfs_log();
    Target target = { .fd = target_fd, .size = target_size, .is_device = is_device,
                      .align = device_alignment(target_fd) };
    if (!target.align) return EIO;
    EditPlan *plans = calloc(count, sizeof(*plans));
    if (!plans) return ENOMEM;
    Work work = { .callback = progress, .context = progress_context, .count = count };
    int status = volume_scan(&target, NULL, safety_warnings);
    if (status == EINPROGRESS && !*safety_warnings && removed_pending) {
        size_t removed = 0;
        status = remove_pending(&target, &removed, failure_stage);
        if (status) goto out;
        *removed_pending = removed;
        *failure_stage = 1;
        status = volume_scan(&target, NULL, safety_warnings);
    }
    if (status) goto out;
    uint64_t units = 0;
    status = plan_edits(&target, edits, plans, count, &units, failed_index);
    if (status) goto out;
    work.total = units + 2;
    work_report(&work, OH_PHASE_PREPARE, 0);

    #ifdef OPENHDD_TESTING
    abort_at_stage(2);
    #endif
    *failure_stage = 2;
    if (set_volume_dirty(&target, 1)) { status = phase_error(&target); goto out; }
    int journaled = 0;
    status = write_edit_journal(&target, edits, plans, count, &journaled);
    if (status) goto out;
    ntfs_volume *volume = mount_rw(&target);
    if (!volume) { status = phase_error(&target); goto out; }
    int result = 0;
    for (size_t i = 0; i < count && !result; ++i) {
        *failed_index = i;
        const OHEdit *edit = &edits[i];
        if (edit->kind == OH_EDIT_DELETE) {
            ntfschar *wide = NULL;
            int length = ntfs_mbstoucs(plans[i].leaf, &wide);
            result = length > 0 && length <= 255 ?
                delete_entry(volume, plans[i].parent_inode, wide, length,
                             plans[i].inode, plans[i].directory, &work, i) : -1;
            free(wide);
        } else if (edit->kind == OH_EDIT_RENAME) {
            result = rename_entry(volume, plans[i].parent, plans[i].leaf, edit->name,
                                  plans[i].temporary);
            work_advance(&work, OH_PHASE_WRITE, i, 1);
        } else if (edit->kind == OH_EDIT_MOVE) {
            result = move_entry(volume, plans[i].parent, plans[i].leaf, edit->name);
            work_advance(&work, OH_PHASE_WRITE, i, 1);
        } else {
            result = make_directory(volume, plans[i].parent, edit->name);
            work_advance(&work, OH_PHASE_WRITE, i, 1);
        }
        #ifdef OPENHDD_TESTING
        if (!result && getenv("OPENHDD_TEST_ABORT_AFTER_FIRST_EDIT")) _exit(86);
        #endif
    }
    int failure = result ? errno : 0;
    work_report(&work, OH_PHASE_SYNC, count - 1);
    if (ntfs_umount(volume, FALSE)) result = -1;
    if (durable_sync(&target)) result = -1;
    if (result) {
        if (failure) errno = failure;
        status = phase_error(&target);
        goto out;
    }

    *failure_stage = 3;
    #ifdef OPENHDD_TESTING
    abort_at_stage(3);
    #endif
    status = check_edits(&target, edits, plans, count, failed_index);
    if (status) goto out;
    if (journaled && remove_journal(&target)) { status = phase_error(&target); goto out; }

    *failure_stage = 6;
    #ifdef OPENHDD_TESTING
    abort_at_stage(6);
    #endif
    if (set_volume_dirty(&target, 0)) { status = phase_error(&target); goto out; }
    uint32_t final_warnings = 0;
    status = volume_scan(&target, NULL, &final_warnings);
    if (status || final_warnings) { status = status ? status : EIO; goto out; }
    *failure_stage = 0;
    work.done = work.total;
    work_report(&work, OH_PHASE_FINISH, count - 1);
    #ifdef OPENHDD_TESTING
    abort_at_stage(0);
    if (getenv("OPENHDD_TEST_REPORT_WRITES"))
        fprintf(stderr, "writes=%llu\n", (unsigned long long)target.write_calls);
    #endif
out:
    free(plans);
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

/* ------------------------------------------------------------------------ */
/* Read-only view for browsing during an edit session                       */
/* ------------------------------------------------------------------------ */

/* Browsing reads many small metadata records (one MFT record per listed
   entry); on USB each is a round trip. The view reads 256 KiB blocks and
   serves small reads from the last one. It never sees a write: the session
   closes the view before writing and opens a fresh one afterwards. */
enum { VIEW_BLOCK = 256 * 1024 };

struct OHView {
    Target target;
    OHNTFSVolume *volume;
    unsigned char *block;
    uint64_t block_offset;
    uint64_t block_length;
};

static int64_t view_read(void *opaque, uint64_t offset, void *buffer, uint64_t length)
{
    OHView *view = opaque;
    if (length > INT64_MAX || offset > INT64_MAX || offset > view->target.size) {
        errno = EOVERFLOW;
        return -1;
    }
    int direct = length >= VIEW_BLOCK / 2;
    #ifdef OPENHDD_TESTING
    if (getenv("OPENHDD_TEST_NO_VIEW_CACHE")) direct = 1;
    #endif
    if (direct)
        return bounded_io(&view->target, buffer, (s64)length, (s64)offset, 0);
    uint64_t done = 0;
    while (done < length) {
        uint64_t at = offset + done;
        if (!(view->block_length && at >= view->block_offset &&
              at < view->block_offset + view->block_length)) {
            uint64_t start = at - at % VIEW_BLOCK;
            uint64_t amount = view->target.size - start;
            if (amount > VIEW_BLOCK) amount = VIEW_BLOCK;
            view->block_length = 0;
            if (bounded_io(&view->target, view->block, (s64)amount, (s64)start, 0) != (s64)amount)
                return done ? (int64_t)done : -1;
            view->block_offset = start;
            view->block_length = amount;
        }
        uint64_t inside = at - view->block_offset;
        uint64_t amount = view->block_length - inside;
        if (amount > length - done) amount = length - done;
        memcpy((unsigned char *)buffer + done, view->block + inside, amount);
        done += amount;
        if (view->block_length < VIEW_BLOCK && at + amount >= view->block_offset + view->block_length)
            break; /* end of the device */
    }
    return (int64_t)done;
}

int oh_view_open(int target_fd, uint64_t target_size, int is_device,
                 OHView **view, uint32_t *safety_warnings)
{
    if (!view || !safety_warnings || target_size < 4096 || target_size > INT64_MAX)
        return EINVAL;
    *view = NULL;
    *safety_warnings = 0;
    quiet_ntfs_log();
    OHView *opened = calloc(1, sizeof(*opened));
    if (!opened) return ENOMEM;
    opened->target = (Target){ .fd = target_fd, .size = target_size,
                               .is_device = is_device,
                               .align = device_alignment(target_fd) };
    int setup = !opened->target.align ? EIO :
        posix_memalign((void **)&opened->block, 4096, VIEW_BLOCK) ? ENOMEM : 0;
    if (setup) {
        free(opened);
        return setup;
    }
    /* Browsing is allowed on a volume that needs checking: it only reads. */
    int status = oh_ntfs_open(view_read, opened, target_size, &opened->volume,
                              safety_warnings);
    if (status) {
        if (opened->target.io_failed) status = EIO;
        free(opened->block);
        free(opened);
        return status;
    }
    *view = opened;
    return 0;
}

void oh_view_close(OHView *view)
{
    if (!view) return;
    oh_ntfs_close(view->volume);
    #ifdef OPENHDD_TESTING
    if (getenv("OPENHDD_TEST_REPORT_READS"))
        fprintf(stderr, "view reads=%llu\n", (unsigned long long)view->target.read_calls);
    #endif
    free(view->block);
    free(view);
}

typedef struct {
    OHViewEntry callback;
    void *context;
    int root;
    int include_recovery;
} ViewListing;

static char *nfc_copy(const char *value)
{
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, value,
                                                   kCFStringEncodingUTF8);
    if (!string) return NULL;
    CFMutableStringRef normal = CFStringCreateMutableCopy(kCFAllocatorDefault, 0, string);
    CFRelease(string);
    if (!normal) return NULL;
    CFStringNormalize(normal, kCFStringNormalizationFormC);
    CFIndex capacity = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(normal), kCFStringEncodingUTF8) + 1;
    char *out = malloc((size_t)capacity);
    if (out && !CFStringGetCString(normal, out, capacity, kCFStringEncodingUTF8)) {
        free(out);
        out = NULL;
    }
    CFRelease(normal);
    return out;
}

static int view_entry(void *opaque, const char *name, const OHNTFSItem *item)
{
    ViewListing *listing = opaque;
    if (!listing->include_recovery && !strncasecmp(name, ".OpenHDD-", 9)) return 0;
    if (listing->root && (name[0] == '$' || !strcmp(name, "System Volume Information")))
        return 0;
    char *normal = nfc_copy(name);
    if (!normal) return ENOMEM;
    OHEntryInfo info = { .kind = (int)item->kind, .special = item->special != 0,
                         .size = item->kind == 1 ? item->size : 0,
                         .modified_ns = item->modified_ns };
    int status = listing->callback(listing->context, normal, &info);
    free(normal);
    return status;
}

int oh_view_list(OHView *view, const char *path, int include_recovery,
                 OHViewEntry callback, void *context)
{
    if (!view || !callback) return EINVAL;
    if (path && *path && !oh_ntfs_valid_directory_path(path)) return EINVAL;
    uint64_t inode = 0;
    int status = resolve_plain_directory(view->volume, path ? path : "", &inode);
    if (status) return status;
    ViewListing listing = { .callback = callback, .context = context,
                            .root = inode == FILE_root, .include_recovery = include_recovery };
    status = oh_ntfs_list(view->volume, inode, view_entry, &listing);
    return view->target.io_failed ? EIO : status;
}

int oh_view_export(OHView *view, const char *path, int out_fd, uint64_t *copied)
{
    if (!view || !path || !*path || !copied || out_fd < 0) return EINVAL;
    *copied = 0;
    char parent[4097];
    const char *leaf = NULL;
    if (!oh_ntfs_valid_directory_path(path) || split_path(path, parent, sizeof(parent), &leaf))
        return EINVAL;
    uint64_t folder = 0;
    OHNTFSItem item;
    int status = resolve_plain_directory(view->volume, parent, &folder);
    if (!status) status = oh_ntfs_lookup(view->volume, folder, leaf, &item);
    if (status) return status;
    if (item.special) return ENOTSUP;
    if (item.kind != 1) return EISDIR;
    unsigned char *buffer = NULL;
    if (posix_memalign((void **)&buffer, 4096, IO_CHUNK)) return ENOMEM;
    for (uint64_t offset = 0; offset < item.size && !status; ) {
        if (cancel_flag) { status = ECANCELED; break; }
        uint64_t amount = item.size - offset;
        if (amount > IO_CHUNK) amount = IO_CHUNK;
        if (oh_ntfs_read(view->volume, item.inode, offset, buffer, amount) != (int64_t)amount) {
            status = EIO;
            break;
        }
        for (uint64_t done = 0; done < amount; ) {
            ssize_t n = write(out_fd, buffer + done, (size_t)(amount - done));
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) { status = errno ? errno : EIO; break; }
            done += (uint64_t)n;
        }
        offset += amount;
        *copied = offset;
    }
    free(buffer);
    return view->target.io_failed ? EIO : status;
}
