#include "WriteEngine.h"
#include "OpenHDDNTFS.h"

#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOKitLib.h>
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <signal.h>
#include <unistd.h>

/* A local marker survives process death even if NTFS lost its pending name
   during the last metadata sync. It is cleared only after normal eject. */
static char quarantine_path[1024] = "/private/var/db/openhdd";
static char quarantine_parent[1024] = "/private/var/db";

/* Root keeps markers system-wide. An unprivileged run can only reach devices
   the user owns (for example an attached disk image) and keeps them in the
   user's Library. */
static int select_quarantine_path(void)
{
    if (geteuid() == 0) return 0;
    const char *home = getenv("HOME");
    struct stat state;
    if (!home || *home != '/' ||
        snprintf(quarantine_parent, sizeof(quarantine_parent),
                 "%s/Library/Application Support", home) >= (int)sizeof(quarantine_parent) ||
        snprintf(quarantine_path, sizeof(quarantine_path),
                 "%s/OpenHDD-markers", quarantine_parent) >= (int)sizeof(quarantine_path) ||
        lstat(quarantine_parent, &state) || !S_ISDIR(state.st_mode) ||
        state.st_uid != geteuid()) return -1;
    return 0;
}

static int quarantine_name(int device, uint64_t size, char *name, size_t length)
{
    unsigned char boot[512];
    if (pread(device, boot, sizeof(boot), 0) != sizeof(boot) ||
        memcmp(boot + 3, "NTFS    ", 8) ||
        boot[510] != 0x55 || boot[511] != 0xaa) return -1;
    uint64_t serial = 0;
    for (size_t i = 0; i < 8; ++i)
        serial |= (uint64_t)boot[0x48 + i] << (i * 8);
    if (!serial || snprintf(name, length, "%016llx-%llu.pending",
        (unsigned long long)serial, (unsigned long long)size) >= (int)length)
        return -1;
    return 0;
}

static int quarantine_directory(int create)
{
    int made_directory = 0;
    if (create && !mkdir(quarantine_path, 0700)) made_directory = 1;
    else if (create && errno != EEXIST) return -1;
    int directory = open(quarantine_path,
                         O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat state;
    if (directory < 0) return -1;
    if (fstat(directory, &state) || !S_ISDIR(state.st_mode) ||
        state.st_uid != geteuid() || (state.st_mode & 077)) {
        close(directory);
        errno = EPERM;
        return -1;
    }
    if (made_directory) {
        int parent = open(quarantine_parent,
                          O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        int synced = parent >= 0 && !fsync(parent);
        if (parent >= 0) close(parent);
        if (!synced) {
            close(directory);
            errno = EIO;
            return -1;
        }
    }
    return directory;
}

static int quarantine_status(int device, uint64_t size)
{
    char name[80];
    if (quarantine_name(device, size, name, sizeof(name))) return -1;
    int directory = quarantine_directory(0);
    if (directory < 0) return errno == ENOENT ? 0 : -1;
    struct stat state;
    int exists = fstatat(directory, name, &state, AT_SYMLINK_NOFOLLOW) == 0;
    int saved_errno = errno;
    close(directory);
    if (!exists && saved_errno != ENOENT) return -1;
    return exists;
}

static int quarantine_begin(int device, uint64_t size, int *directory,
                            char *name, size_t length)
{
    if (quarantine_name(device, size, name, length)) return EINVAL;
    *directory = quarantine_directory(1);
    if (*directory < 0) return errno ? errno : EIO;
    int marker = openat(*directory, name,
                        O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                        0600);
    if (marker < 0) return errno == EEXIST ? EINPROGRESS : (errno ? errno : EIO);
    int result = fsync(marker);
    if (close(marker)) result = -1;
    if (fsync(*directory)) result = -1;
    return result ? EIO : 0;
}

static int quarantine_clear(int directory, const char *name)
{
    return unlinkat(directory, name, 0) || fsync(directory) ? -1 : 0;
}

typedef struct {
    DASessionRef session;
    DADiskRef partition;
    DADiskRef whole;
    uint64_t registry_id;
    uint64_t size;
    int claimed;
} DiskLease;

typedef struct {
    int finished;
    int status;
} DiskRequest;

static int partition_name(const char *name)
{
    if (strncmp(name, "disk", 4)) return 0;
    const char *cursor = name + 4;
    if (*cursor < '0' || *cursor > '9') return 0;
    while (*cursor >= '0' && *cursor <= '9') ++cursor;
    if (*cursor++ != 's' || *cursor < '0' || *cursor > '9') return 0;
    while (*cursor >= '0' && *cursor <= '9') ++cursor;
    return !*cursor;
}

static void disk_finished(DADiskRef disk, DADissenterRef dissenter, void *opaque)
{
    (void)disk;
    DiskRequest *request = opaque;
    request->status = dissenter ? (int)DADissenterGetStatus(dissenter) : 0;
    request->finished = 1;
    CFRunLoopStop(CFRunLoopGetCurrent());
}

static DADissenterRef deny_release(DADiskRef disk, void *opaque)
{
    (void)disk; (void)opaque;
    return DADissenterCreate(kCFAllocatorDefault, kDAReturnExclusiveAccess,
                             CFSTR("OpenHDD transfer in progress"));
}

static void print_safety_warnings(uint32_t warnings)
{
    if (!warnings) return;
    fputs("NTFS safety preflight refused: ", stderr);
    if (warnings & OH_NTFS_WARNING_DIRTY) fputs("dirty volume; ", stderr);
    if (warnings & OH_NTFS_WARNING_HIBERNATED_OR_UNCERTAIN)
        fputs("hibernation state uncertain; ", stderr);
    if (warnings & OH_NTFS_WARNING_JOURNAL_SUSPECT)
        fputs("journal state suspect; ", stderr);
    if (warnings & OH_NTFS_WARNING_TXF_REWRITE_RISK)
        fputs("$TXF_DATA rewrite risk; ", stderr);
    fputs("no writes started.\n", stderr);
}

static int wait_request(DiskRequest *request)
{
    while (!request->finished)
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 1.0, true);
    return request->status;
}

static int disk_unmount(DADiskRef whole)
{
    DiskRequest request = {0};
    DADiskUnmount(whole, kDADiskUnmountOptionWhole, disk_finished, &request);
    return wait_request(&request);
}

static int disk_eject(DADiskRef whole)
{
    DiskRequest request = {0};
    DADiskEject(whole, kDADiskEjectOptionDefault, disk_finished, &request);
    return wait_request(&request);
}

static int mounted_path(DADiskRef disk, char *path, size_t capacity)
{
    CFDictionaryRef description = DADiskCopyDescription(disk);
    if (!description) return -1;
    CFURLRef url = CFDictionaryGetValue(description,
                                        kDADiskDescriptionVolumePathKey);
    int mounted = url && CFURLGetFileSystemRepresentation(
        url, true, (UInt8 *)path, capacity);
    CFRelease(description);
    return mounted ? 1 : 0;
}

static int restore_read_only(DADiskRef disk)
{
    DiskRequest request = {0};
    CFStringRef arguments[] = { CFSTR("rdonly"), NULL };
    DADiskMountWithArguments(disk, NULL, kDADiskMountOptionDefault,
                             disk_finished, &request, arguments);
    if (wait_request(&request)) return -1;
    char path[1024];
    struct statfs state;
    if (mounted_path(disk, path, sizeof(path)) != 1 ||
        statfs(path, &state) || !(state.f_flags & MNT_RDONLY)) {
        DiskRequest undo = {0};
        DADiskUnmount(disk, kDADiskUnmountOptionDefault, disk_finished, &undo);
        (void)wait_request(&undo);
        return -1;
    }
    return 0;
}

static int disk_claim(DiskLease *lease)
{
    DiskRequest request = {0};
    DADiskClaim(lease->whole, kDADiskClaimOptionDefault,
                deny_release, NULL, disk_finished, &request);
    int result = wait_request(&request);
    if (!result) lease->claimed = 1;
    return result;
}

static int copy_number(CFDictionaryRef description, CFStringRef key,
                       uint64_t *out)
{
    CFNumberRef number = CFDictionaryGetValue(description, key);
    int64_t value = 0;
    if (!number || CFGetTypeID(number) != CFNumberGetTypeID() ||
        !CFNumberGetValue(number, kCFNumberSInt64Type, &value) || value <= 0)
        return -1;
    *out = (uint64_t)value;
    return 0;
}

static int bool_value(CFDictionaryRef description, CFStringRef key,
                      int default_value)
{
    CFBooleanRef value = CFDictionaryGetValue(description, key);
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID())
        return default_value;
    return CFBooleanGetValue(value);
}

static int inspect_partition(DiskLease *lease, const char *name,
                             int must_be_unmounted)
{
    DADiskRef current = DADiskCreateFromBSDName(kCFAllocatorDefault,
                                                lease->session, name);
    if (!current) return -1;
    CFDictionaryRef description = DADiskCopyDescription(current);
    io_service_t media = DADiskCopyIOMedia(current);
    uint64_t registry = 0, size = 0;
    if (media) {
        IORegistryEntryGetRegistryEntryID(media, &registry);
        IOObjectRelease(media);
    }
    int valid = 0;
    if (description && registry && !copy_number(description,
        kDADiskDescriptionMediaSizeKey, &size)) {
        CFStringRef kind = CFDictionaryGetValue(
            description, kDADiskDescriptionVolumeKindKey);
        int external = !bool_value(description,
            kDADiskDescriptionDeviceInternalKey, 1) ||
            bool_value(description, kDADiskDescriptionMediaRemovableKey, 0);
        valid = external &&
            !bool_value(description, kDADiskDescriptionMediaWholeKey, 1) &&
            kind && CFGetTypeID(kind) == CFStringGetTypeID() &&
            CFStringCompare(kind, CFSTR("ntfs"),
                            kCFCompareCaseInsensitive) == kCFCompareEqualTo &&
            (!must_be_unmounted || !CFDictionaryGetValue(
                description, kDADiskDescriptionVolumePathKey)) &&
            (!lease->registry_id || registry == lease->registry_id) &&
            (!lease->size || size == lease->size);
    }
    if (valid && !lease->registry_id) {
        lease->registry_id = registry;
        lease->size = size;
    }
    if (description) CFRelease(description);
    CFRelease(current);
    return valid ? 0 : -1;
}

static void lease_close(DiskLease *lease)
{
    if (lease->claimed) DADiskUnclaim(lease->whole);
    if (lease->whole) CFRelease(lease->whole);
    if (lease->partition) CFRelease(lease->partition);
    if (lease->session) {
        DASessionUnscheduleFromRunLoop(lease->session, CFRunLoopGetCurrent(),
                                       kCFRunLoopDefaultMode);
        CFRelease(lease->session);
    }
}

static int private_image(const char *path, const struct stat *image)
{
    if (!S_ISREG(image->st_mode) || image->st_uid != geteuid() ||
        (image->st_mode & 077) || image->st_nlink != 1) return 0;
    char *parent = strdup(path);
    if (!parent) return 0;
    char *slash = strrchr(parent, '/');
    if (!slash || slash == parent) { free(parent); return 0; }
    *slash = 0;
    struct stat directory;
    int valid = !lstat(parent, &directory) && S_ISDIR(directory.st_mode) &&
        directory.st_uid == geteuid() && !(directory.st_mode & 077);
    free(parent);
    return valid;
}

static int display_value(DADiskRef disk, CFStringRef key,
                         char *output, size_t capacity)
{
    CFDictionaryRef description = DADiskCopyDescription(disk);
    if (!description) return -1;
    CFStringRef value = CFDictionaryGetValue(description, key);
    int valid = value && CFGetTypeID(value) == CFStringGetTypeID() &&
        CFStringGetCString(value, output, capacity, kCFStringEncodingUTF8);
    CFRelease(description);
    if (!valid || !output[0]) return -1;
    for (char *cursor = output; *cursor; ++cursor)
        if ((unsigned char)*cursor < 32 || (unsigned char)*cursor == 127)
            *cursor = '?';
    return 0;
}


typedef struct {
    const char *target;          /* image path or partition name */
    const char *directory;       /* NFC, or NULL for the root */
    const char *progress_path;
    int assume_confirmed;
    int eject;
    long owner_uid;              /* -1 when unknown */
    size_t count;
    const char **sources;
    char **names;                /* NFC copies owned by the request */
    char **folders;              /* per-file folder (NFC) from a manifest */
    unsigned char *replace;      /* per-file replace flag from a manifest */
    int replace_all;             /* --replace for SOURCE NAME pairs */
    uint64_t *sizes;             /* filled by check_sources */
    char **directories;          /* folders to create, parents first */
    size_t directory_count;
    char *manifest;              /* raw manifest; source paths point into it */
    int edit_kind;               /* 0 for a copy, else OH_EDIT_* */
    size_t edit_count;
    OHEdit *edits;
    char **edit_strings;         /* NFC paths and names owned by the request */
    size_t edit_string_count;
} CopyRequest;

typedef struct {
    int fd;
    size_t count;
    int last_phase;
} ProgressFile;

static int confirm_disk(DiskLease *lease, const char *name);

/* Converts a UTF-8 argument to NFC, the form Windows tools expect. */
static char *normalized_copy(const char *value)
{
    CFStringRef string = CFStringCreateWithCString(kCFAllocatorDefault, value,
                                                   kCFStringEncodingUTF8);
    if (!string) return NULL;
    CFMutableStringRef normal = CFStringCreateMutableCopy(kCFAllocatorDefault,
                                                          0, string);
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

static void request_free(CopyRequest *request)
{
    if (request->names)
        for (size_t i = 0; i < request->count; ++i) free(request->names[i]);
    if (request->folders)
        for (size_t i = 0; i < request->count; ++i) free(request->folders[i]);
    for (size_t i = 0; request->directories && i < request->directory_count; ++i)
        free(request->directories[i]);
    free(request->folders);
    free(request->directories);
    free(request->replace);
    free(request->sizes);
    free(request->manifest);
    for (size_t i = 0; i < request->edit_string_count; ++i) free(request->edit_strings[i]);
    free(request->edit_strings);
    free(request->edits);
    free(request->names);
    free(request->sources);
    free((char *)request->directory);
}

/* One line, rewritten in place: "phase file count done total". */
static void report_progress(void *opaque, int phase, size_t index, size_t count,
                            uint64_t done, uint64_t total)
{
    ProgressFile *progress = opaque;
    char line[128];
    int length = snprintf(line, sizeof(line), "%d %zu %zu %llu %llu\n", phase,
                          index, count, (unsigned long long)done,
                          (unsigned long long)total);
    if (progress->fd >= 0 && length > 0) {
        /* The file holds only the latest line; errors are not fatal. */
        if (pwrite(progress->fd, line, (size_t)length, 0) == length)
            (void)ftruncate(progress->fd, length);
    } else if (progress->fd < 0 && phase != progress->last_phase) {
        static const char *names[] = { "Checking", "Writing", "Syncing",
                                       "Verifying", "Publishing", "Finishing" };
        if (phase >= 0 && phase <= 5)
            fprintf(stderr, "%s... (%llu%%)\n", names[phase],
                    total ? (unsigned long long)(done * 100 / total) : 0ULL);
        progress->last_phase = phase;
    }
}

/* The progress file is created by the unprivileged caller; refuse anything
   that could redirect a root write elsewhere. */
static int open_progress(const char *path, long owner_uid)
{
    if (!path) return -1;
    int fd = open(path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat state;
    if (fd >= 0 && (fstat(fd, &state) || !S_ISREG(state.st_mode) ||
                    state.st_nlink != 1 ||
                    (owner_uid >= 0 && state.st_uid != (uid_t)owner_uid))) {
        close(fd);
        return -1;
    }
    return fd;
}

static int open_source(const CopyRequest *request, long owner_uid, size_t i,
                       uint64_t *size)
{
    struct stat state;
    int fd = open(request->sources[i], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) {
        fprintf(stderr, "Refused: source %zu could not be opened: %s.\n",
                i + 1, strerror(errno));
        return -1;
    }
    if (fstat(fd, &state) || !S_ISREG(state.st_mode) ||
        (owner_uid >= 0 && state.st_uid != (uid_t)owner_uid &&
         !(state.st_mode & S_IROTH))) {
        close(fd);
        fprintf(stderr, "Refused: source %zu is not a regular file readable "
                        "by the requesting user.\n", i + 1);
        return -1;
    }
    if (size) *size = (uint64_t)state.st_size;
    return fd;
}

/* Every source is opened once before the drive is touched, so a missing or
   unreadable file is refused while the volume is still mounted. */
static int check_sources(CopyRequest *request, long owner_uid)
{
    request->sizes = calloc(request->count + 1, sizeof(*request->sizes));
    if (!request->sizes) return -1;
    for (size_t i = 0; i < request->count; ++i) {
        int fd = open_source(request, owner_uid, i, &request->sizes[i]);
        if (fd < 0) return -1;
        close(fd);
    }
    return 0;
}

static int open_sources(const CopyRequest *request, long owner_uid,
                        OHCopyItem *items, size_t start, size_t count)
{
    for (size_t i = 0; i < count; ++i) items[i].source_fd = -1;
    for (size_t i = 0; i < count; ++i) {
        size_t index = start + i;
        items[i].source_fd = open_source(request, owner_uid, index, NULL);
        if (items[i].source_fd < 0) return -1;
        items[i].destination_name = request->names[index];
        items[i].directory = request->folders ? request->folders[index] :
                                                request->directory;
        items[i].replace = request->replace ? request->replace[index] :
                                              request->replace_all;
    }
    return 0;
}

static void close_sources(OHCopyItem *items, size_t count)
{
    for (size_t i = 0; i < count; ++i)
        if (items[i].source_fd >= 0) close(items[i].source_fd);
}

static void explain_failure(int code, int stage, size_t index, size_t count,
                            uint32_t warnings)
{
    if (code == ECANCELED && stage == 1) {
        fputs("Cancelled: the files of the batch in progress were removed; the "
              "volume is clean.\n", stderr);
        return;
    }
    if (code == EINPROGRESS) {
        fputs("Refused: unfinished OpenHDD transfer found. Check the volume on "
              "Windows (chkdsk X: /f); no new copy started.\n", stderr);
        return;
    }
    print_safety_warnings(warnings);
    if (stage == 1) {
        if (code == EEXIST)
            fprintf(stderr, "Refused: a file named like item %zu already exists "
                            "(names are case-insensitive).\n", index + 1);
        else if (code == ENOSPC)
            fputs("Refused: not enough free space for all files plus reserve.\n",
                  stderr);
        else if (code == ENOENT || code == ENOTDIR)
            fprintf(stderr, "Refused: %s not found on the volume.\n",
                    stage == 1 && index ? "an item" : "the item or destination folder");
        else if (code == EINVAL)
            fprintf(stderr, "Refused: invalid name or source for item %zu.\n",
                    index + 1);
        else if (code == EACCES)
            fprintf(stderr, "Refused: item %zu is a protected system entry.\n",
                    index + 1);
        else if (code == EISDIR)
            fprintf(stderr, "Refused: item %zu would replace a folder with a "
                            "file.\n", index + 1);
        else if (code == ENOTSUP)
            fprintf(stderr, "Refused: item %zu is or contains a junction, symbolic "
                            "link or encrypted file; nothing changed.\n", index + 1);
        else if (!warnings && code == EBUSY)
            fputs("Preflight refused: volume busy or safety state uncertain; "
                  "no writes started.\n", stderr);
    }
    if (code == ESTALE)
        fprintf(stderr, "Refused: source %zu changed while it was being copied; "
                        "nothing was published.\n", index + 1);
    if (*oh_last_error())
        fprintf(stderr, "Detail: %s.\n", oh_last_error());
    fprintf(stderr, "Copy failed at stage %d; code %d; item %zu of %zu.\n",
            stage, code, index + 1, count);
    if (stage >= 2)
        fputs("The volume is marked for checking. Connect it to Windows and "
              "run chkdsk X: /f before writing again. Files that existed before "
              "this copy were not modified.\n", stderr);
}

static int run_check_image(const char *path)
{
    struct stat before;
    if (lstat(path, &before) || !S_ISREG(before.st_mode)) {
        fputs("Refused: target must be a regular image.\n", stderr);
        return 1;
    }
    int target = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (target < 0) { perror("open"); return 1; }
    uint64_t free_bytes = 0;
    uint32_t warnings = 0;
    int code = oh_ntfs_safety_preflight(target, (uint64_t)before.st_size,
                                        &free_bytes, &warnings);
    close(target);
    printf("dirty=%d hibernation=%d journal=%d txf=%d pending=%d code=%d free=%llu\n",
           !!(warnings & OH_NTFS_WARNING_DIRTY),
           !!(warnings & OH_NTFS_WARNING_HIBERNATED_OR_UNCERTAIN),
           !!(warnings & OH_NTFS_WARNING_JOURNAL_SUSPECT),
           !!(warnings & OH_NTFS_WARNING_TXF_REWRITE_RISK),
           code == EINPROGRESS, code, (unsigned long long)free_bytes);
    return code ? 1 : 0;
}

static size_t request_items(const CopyRequest *request)
{
    return request->edit_kind ? request->edit_count : request->count;
}

/* Large copies run as several complete sessions: an interruption touches
   one batch only and the number of open files stays bounded. */
enum { BATCH_FILES = 1000 };
static const uint64_t batch_bytes = 8ULL * 1024 * 1024 * 1024;
static size_t batch_limit = BATCH_FILES;

static size_t batch_end(const CopyRequest *request, size_t start)
{
    size_t end = start;
    uint64_t bytes = 0;
    while (end < request->count && end - start < batch_limit &&
           (end == start || bytes + request->sizes[end] <= batch_bytes))
        bytes += request->sizes[end++];
    return end;
}

static uint64_t batch_units(const CopyRequest *request, size_t start, size_t end)
{
    uint64_t bytes = 0;
    for (size_t i = start; i < end; ++i) bytes += request->sizes[i];
    return oh_copy_work_units(bytes, end - start,
                              start ? 0 : request->directory_count);
}

typedef struct {
    ProgressFile *file;
    size_t file_base, file_total;
    uint64_t unit_base, unit_total;
} BatchProgress;

/* Maps one batch's progress onto the whole request: one bar, one ETA. */
static void report_batch(void *opaque, int phase, size_t index, size_t count,
                         uint64_t done, uint64_t total)
{
    (void)count; (void)total;
    BatchProgress *batch = opaque;
    uint64_t overall = batch->unit_base + done;
    if (overall > batch->unit_total) overall = batch->unit_total;
    report_progress(batch->file, phase, batch->file_base + index,
                    batch->file_total, overall, batch->unit_total);
}

/* Ctrl-C (or the app's Cancel, which sends SIGINT) asks the engine to stop
   at a safe point instead of killing the process mid-write. */
static void request_cancel(int signal_number)
{
    (void)signal_number;
    oh_request_cancel();
}

/* Installed for the whole session once it is confirmed: a request to stop
   during unmount or authorization is honoured by the engine before it
   writes anything, and the volume is remounted as usual. */
static void install_cancel_handler(void)
{
    struct sigaction cancel = { .sa_handler = request_cancel, .sa_flags = SA_RESTART };
    sigemptyset(&cancel.sa_mask);
    sigaction(SIGINT, &cancel, NULL);
}

static int run_engine(const CopyRequest *request, long owner_uid, int fd,
                      uint64_t size, int is_device, ProgressFile *progress,
                      size_t *failed, int *stage, uint32_t *warnings,
                      size_t *removed)
{
    if (request->edit_kind)
        return oh_edit_volume(fd, size, is_device, request->edits,
                              request->edit_count, report_progress, progress,
                              failed, stage, warnings, removed);
    OHCopyItem *items = calloc(batch_limit, sizeof(*items));
    if (!items) return ENOMEM;
    BatchProgress batch = { .file = progress, .file_total = request->count };
    for (size_t start = 0, end; start < request->count || !start; start = end) {
        end = batch_end(request, start);
        batch.unit_total += batch_units(request, start, end);
        if (end == start) break;
    }
    int code = 0;
    size_t start = 0;
    *removed = 0;
    do {
        size_t end = batch_end(request, start);
        size_t batch_removed = 0;
        if (oh_cancel_requested()) {
            *stage = 1;
            *failed = start;
            code = ECANCELED;
            if (start)
                fprintf(stderr, "Earlier batches: %zu file(s) were already copied "
                                "and verified; they stay on the volume.\n", start);
            break;
        }
        if (open_sources(request, owner_uid, items, start, end - start)) {
            close_sources(items, end - start);
            *stage = 1;
            *failed = start;
            code = EBADF;
            break;
        }
        code = oh_copy_files(fd, size, is_device,
                             start ? NULL : (const char *const *)request->directories,
                             start ? 0 : request->directory_count,
                             items, end - start, report_batch, &batch,
                             failed, stage, warnings, &batch_removed);
        close_sources(items, end - start);
        *removed += batch_removed;
        if (code) {
            *failed += start;
            if (start)
                fprintf(stderr, "Earlier batches: %zu file(s) were already copied "
                                "and verified; they stay on the volume.\n", start);
            break;
        }
        batch.unit_base += batch_units(request, start, end);
        batch.file_base = end;
        start = end;
    } while (start < request->count);
    free(items);
    return code;
}

static void print_pass(const CopyRequest *request, const char *suffix)
{
    if (request->edit_kind)
        printf("PASS: %zu change(s) applied, verified; volume clean%s.\n",
               request->edit_count, suffix);
    else if (request->directory_count)
        printf("PASS: %zu file(s) and %zu folder(s) copied, independently "
               "verified; volume clean%s.\n", request->count,
               request->directory_count, suffix);
    else
        printf("PASS: %zu file(s) copied, independently verified; volume clean%s.\n",
               request->count, suffix);
}

static int run_image(CopyRequest *request)
{
    struct stat before, after;
    int result = 1, stage = 0;
    uint32_t warnings = 0;
    size_t failed = 0;
    const char *path = request->target;
    if (!request->edit_kind) install_cancel_handler();
    if (lstat(path, &before) || !private_image(path, &before)) {
        fputs("Refused: target must be a private regular image.\n", stderr);
        return 1;
    }
    int target = open(path, O_RDWR | O_EXCL | O_NOFOLLOW | O_CLOEXEC);
    if (target < 0 || fstat(target, &after) ||
        before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        before.st_size != after.st_size ||
        (!request->edit_kind && check_sources(request, -1))) {
        fputs("Refused: image or source changed.\n", stderr);
        goto out;
    }
    ProgressFile progress = { .fd = open_progress(request->progress_path, -1),
                              .count = request->count, .last_phase = -1 };
    size_t removed = 0;
    int code = run_engine(request, -1, target, (uint64_t)after.st_size, 0,
                          &progress, &failed, &stage, &warnings, &removed);
    if (removed)
        fprintf(stderr, "Removed %zu OpenHDD temporary file(s) left by an earlier "
                        "interrupted copy.\n", removed);
    if (progress.fd >= 0) close(progress.fd);
    if (code) explain_failure(code, stage, failed, request_items(request), warnings);
    else result = 0;
out:
    if (target >= 0 && close(target)) {
        fputs("Image close failed; no success reported.\n", stderr);
        result = 1;
    }
    if (!result) print_pass(request, "");
    return result;
}

/* Asks macOS once for both rights authopen needs: an exclusive read-only
   open of the block device (it keeps the volume from being mounted) and a
   read-write open of the raw device used for fast I/O. */
static int authorize_device(const char *block, const char *raw,
                            const char *volume_name,
                            AuthorizationExternalForm *external)
{
    char read_right[128], write_right[128], prompt[512];
    snprintf(read_right, sizeof(read_right), "sys.openfile.readonly.%s", block);
    snprintf(write_right, sizeof(write_right), "sys.openfile.readwrite.%s", raw);
    snprintf(prompt, sizeof(prompt),
             "OpenHDD deve scrivere sul disco NTFS \xC2\xAB%s\xC2\xBB.",
             volume_name && *volume_name ? volume_name : "esterno");
    AuthorizationItem rights[] = {
        { read_right, 0, NULL, 0 }, { write_right, 0, NULL, 0 } };
    AuthorizationRights set = { 2, rights };
    AuthorizationItem prompt_item = { kAuthorizationEnvironmentPrompt,
                                      strlen(prompt), prompt, 0 };
    AuthorizationEnvironment environment = { 1, &prompt_item };
    AuthorizationRef authorization = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                          kAuthorizationFlagDefaults, &authorization);
    if (status == errAuthorizationSuccess)
        status = AuthorizationCopyRights(authorization, &set, &environment,
            kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights |
            kAuthorizationFlagPreAuthorize, NULL);
    if (status == errAuthorizationSuccess)
        status = AuthorizationMakeExternalForm(authorization, external);
    /* The external form stays valid while this process keeps the reference. */
    return status == errAuthorizationSuccess ? 0 : -1;
}

/* Opens the partition through Apple's authopen: macOS asks for an
   administrator password and hands back only this descriptor, so the copy
   itself keeps running as the user (with the app's file permissions). */
static int authopen_device(const char *path, int flags,
                           const AuthorizationExternalForm *authorization)
{
    int pair[2], input[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) return -1;
    if (pipe(input)) { close(pair[0]); close(pair[1]); return -1; }
    pid_t child = fork();
    if (child < 0) {
        close(pair[0]); close(pair[1]); close(input[0]); close(input[1]);
        return -1;
    }
    if (child == 0) {
        char text[16];
        snprintf(text, sizeof(text), "%d", flags);
        if (dup2(pair[1], STDOUT_FILENO) < 0 || dup2(input[0], STDIN_FILENO) < 0)
            _exit(127);
        close(pair[0]); close(pair[1]); close(input[0]); close(input[1]);
        execl("/usr/libexec/authopen", "authopen", "-stdoutpipe", "-extauth",
              "-o", text, path, (char *)NULL);
        _exit(127);
    }
    close(input[0]);
    ssize_t sent = write(input[1], authorization, sizeof(*authorization));
    close(input[1]);
    if (sent != (ssize_t)sizeof(*authorization)) {
        close(pair[0]); close(pair[1]);
        waitpid(child, NULL, 0);
        errno = EACCES;
        return -1;
    }
    close(pair[1]);
    int fd = -1;
    char byte = 0;
    union {
        struct cmsghdr header;
        char space[CMSG_SPACE(sizeof(int))];
    } control;
    struct iovec vector = { .iov_base = &byte, .iov_len = 1 };
    struct msghdr message = {
        .msg_iov = &vector, .msg_iovlen = 1,
        .msg_control = control.space, .msg_controllen = sizeof(control.space)
    };
    ssize_t got;
    do got = recvmsg(pair[0], &message, 0); while (got < 0 && errno == EINTR);
    struct cmsghdr *header = got > 0 ? CMSG_FIRSTHDR(&message) : NULL;
    if (header && header->cmsg_level == SOL_SOCKET &&
        header->cmsg_type == SCM_RIGHTS &&
        header->cmsg_len == CMSG_LEN(sizeof(int)))
        memcpy(&fd, CMSG_DATA(header), sizeof(fd));
    close(pair[0]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    if (fd >= 0 && (!WIFEXITED(status) || WEXITSTATUS(status))) {
        close(fd);
        fd = -1;
    }
    if (fd < 0) { errno = EACCES; return -1; }
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) ||
        (fcntl(fd, F_GETFL) & O_ACCMODE) != (flags & O_ACCMODE)) {
        close(fd);
        errno = EACCES;
        return -1;
    }
    return fd;
}

static int run_disk(CopyRequest *request)
{
    const char *name = request->target;
    long owner_uid = geteuid() == 0 ? request->owner_uid : (long)getuid();
    if (!partition_name(name) || owner_uid < 0 || select_quarantine_path()) {
        fputs("Refused: use a partition name such as disk4s1; as root, also "
              "give --owner-uid or run through sudo.\n", stderr);
        return 1;
    }
    int result = 1, stage = 0, target = -1, hold = -1;
    int quarantine_dir = -1, quarantine_active = 0;
    char quarantine_file[80] = {0};
    uint32_t warnings = 0;
    size_t failed = 0;
    int had_mount = 0, unmounted = 0, wrote = 0;
    DiskLease lease = {0};
    lease.session = DASessionCreate(kCFAllocatorDefault);
    if (!lease.session) goto out;
    DASessionScheduleWithRunLoop(lease.session, CFRunLoopGetCurrent(),
                                 kCFRunLoopDefaultMode);
    lease.partition = DADiskCreateFromBSDName(kCFAllocatorDefault,
                                               lease.session, name);
    if (!lease.partition || inspect_partition(&lease, name, 0)) {
        fputs("Refused: target is not an external NTFS partition.\n", stderr);
        goto out;
    }
    char existing_path[1024];
    had_mount = mounted_path(lease.partition, existing_path,
                             sizeof(existing_path)) == 1;
    lease.whole = DADiskCopyWholeDisk(lease.partition);
    if (!lease.whole) goto out;
    if (!request->assume_confirmed && confirm_disk(&lease, name)) {
        fputs("Not confirmed; nothing written.\n", stderr);
        goto out;
    }
    if (!request->edit_kind) install_cancel_handler();
    if (!request->edit_kind && check_sources(request, owner_uid)) goto out;
    if (disk_unmount(lease.whole)) {
        fputs("Refused: normal unmount failed (a file on the drive may be open); "
              "no force used.\n", stderr);
        goto out;
    }
    unmounted = 1;
    if (disk_claim(&lease) || inspect_partition(&lease, name, 1)) {
        fputs("Refused: exclusive claim or device identity failed.\n", stderr);
        goto out;
    }
    char path[64];
    snprintf(path, sizeof(path), "/dev/%s", name);
    /* The file-system service may release the device a moment after the
       unmount completes; only "busy" is retried, for up to five seconds. */
    char raw_path[64];
    snprintf(raw_path, sizeof(raw_path), "/dev/r%s", name);
    int via_authopen = geteuid() != 0 &&
        (access(path, R_OK) != 0 || access(raw_path, R_OK | W_OK) != 0);
    AuthorizationExternalForm external;
    if (via_authopen) {
        char volume[256] = "";
        (void)display_value(lease.partition, kDADiskDescriptionVolumeNameKey,
                            volume, sizeof(volume));
        if (authorize_device(path, raw_path, volume, &external)) {
            fputs("Refused: administrator authorization for the drive was denied "
                  "or cancelled; nothing written.\n", stderr);
            goto out;
        }
    }
    /* The block device held exclusively keeps anyone from mounting the
       volume; all I/O goes through the raw device in large transfers. The
       file-system service may release the device a moment after the unmount
       completes, so only "busy" is retried, for up to five seconds. */
    for (int attempt = 0; attempt < 20; ++attempt) {
        hold = via_authopen ? authopen_device(path, O_RDONLY | O_EXCL, &external) :
            open(path, O_RDONLY | O_EXCL | O_NOFOLLOW | O_CLOEXEC);
        if (hold >= 0 || errno != EBUSY) break;
        usleep(250000);
    }
    if (hold < 0) {
        fprintf(stderr, "Refused: device access failed: exclusive open of %s: %s.\n",
                path, strerror(errno));
        goto out;
    }
    target = via_authopen ? authopen_device(raw_path, O_RDWR, &external) :
        open(raw_path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat target_info, hold_info;
    uint32_t block_size = 0;
    uint64_t block_count = 0;
    if (target < 0) {
        fprintf(stderr, "Refused: device access failed: open of %s: %s.\n",
                raw_path, strerror(errno));
        goto out;
    }
    if (fstat(target, &target_info) || !S_ISCHR(target_info.st_mode) ||
        fstat(hold, &hold_info) || !S_ISBLK(hold_info.st_mode) ||
        target_info.st_rdev != hold_info.st_rdev) {
        fputs("Refused: device access failed: raw and block devices do not match.\n",
              stderr);
        goto out;
    }
    if (ioctl(target, DKIOCGETBLOCKSIZE, &block_size) ||
        ioctl(target, DKIOCGETBLOCKCOUNT, &block_count)) {
        fprintf(stderr, "Refused: device access failed: geometry query: %s.\n",
                strerror(errno));
        goto out;
    }
    if (block_size < 512 || block_size > 65536 ||
        block_count != lease.size / block_size || lease.size % block_size) {
        fprintf(stderr, "Refused: device geometry mismatch: block size %u, count "
                "%llu, expected %llu bytes.\n", block_size,
                (unsigned long long)block_count, (unsigned long long)lease.size);
        goto out;
    }
    if (inspect_partition(&lease, name, 1)) {
        fputs("Refused: device identity changed after the exclusive open.\n",
              stderr);
        goto out;
    }
    /* A marker left by an earlier session no longer blocks forever: the
       dirty mark protects the volume itself, so a volume that now passes the
       preflight (Windows checked it, or nothing was written) is usable. */
    if (quarantine_status(target, lease.size) > 0) {
        uint64_t free_bytes = 0;
        uint32_t marker_warnings = 0;
        int marker_check = oh_ntfs_safety_preflight(target, lease.size,
                                                    &free_bytes, &marker_warnings);
        /* Leftover temporaries on a clean volume are removed by the copy. */
        if (marker_check && !(marker_check == EINPROGRESS && !marker_warnings)) {
            /* The volume's own state is the actionable reason; the local
               marker is only mentioned when nothing else is wrong. */
            if (marker_warnings) print_safety_warnings(marker_warnings);
            else
                fputs("Refused: previous OpenHDD transfer unresolved on this Mac. "
                      "Check the volume on Windows (chkdsk X: /f) first.\n", stderr);
            goto out;
        }
        char stale[80];
        int directory = -1;
        if (quarantine_name(target, lease.size, stale, sizeof(stale)) ||
            (directory = quarantine_directory(0)) < 0 ||
            quarantine_clear(directory, stale)) {
            if (directory >= 0) close(directory);
            fputs("Refused: stale local safety marker could not be cleared.\n",
                  stderr);
            goto out;
        }
        close(directory);
        fputs("Earlier unfinished transfer: volume now checks clean; "
              "local marker cleared.\n", stderr);
    }
    int marker_status = quarantine_begin(target, lease.size, &quarantine_dir,
                                         quarantine_file,
                                         sizeof(quarantine_file));
    if (marker_status) {
        fputs("Refused: local safety marker could not be secured. "
              "No NTFS write started.\n", stderr);
        goto out;
    }
    quarantine_active = 1;
    ProgressFile progress = {
        .fd = open_progress(request->progress_path, owner_uid),
        .count = request->count, .last_phase = -1 };
    size_t removed = 0;
    int code = run_engine(request, owner_uid, target, lease.size, 1, &progress,
                          &failed, &stage, &warnings, &removed);
    if (removed)
        fprintf(stderr, "Removed %zu OpenHDD temporary file(s) left by an earlier "
                        "interrupted copy.\n", removed);
    if (progress.fd >= 0) close(progress.fd);
    if (code) {
        if (stage == 1 && !quarantine_clear(quarantine_dir, quarantine_file))
            quarantine_active = 0; /* preflight never enters RW mount */
        explain_failure(code, stage, failed, request_items(request), warnings);
        goto out;
    }
    wrote = 1;
    if (inspect_partition(&lease, name, 1)) {
        fputs("Copy verified, but device identity changed. No success reported.\n",
              stderr);
        goto out;
    }
    result = 0;
out:
    if (target >= 0 && close(target)) {
        fputs("Device close failed; no success reported.\n", stderr);
        result = 1;
    }
    /* Last close of the block device drops any cached blocks of the volume. */
    if (hold >= 0) close(hold);
    if (lease.claimed) {
        int same_device = inspect_partition(&lease, name, 1) == 0;
        DADiskUnclaim(lease.whole);
        lease.claimed = 0;
        if (!same_device) {
            fputs("Device identity changed; automatic remount skipped.\n", stderr);
            result = 1;
        } else if (request->eject) {
            if (disk_unmount(lease.whole) || disk_eject(lease.whole)) {
                fputs("Eject failed; keep drive connected and inspect it.\n", stderr);
                result = 1;
            }
        } else if (restore_read_only(lease.partition)) {
            /* Data and metadata are already synced; only the view failed. */
            fputs(wrote ? "Copy complete, but the read-only remount failed; "
                          "eject and reconnect the drive to see the files.\n" :
                          "Read-only remount failed.\n", stderr);
        }
    } else if (unmounted && had_mount && inspect_partition(&lease, name, 1) == 0) {
        if (restore_read_only(lease.partition))
            fputs("Previous read-only mount could not be restored.\n", stderr);
        else
            fputs("Previous read-only mount restored.\n", stderr);
    }
    if (!result && quarantine_active) {
        if (quarantine_clear(quarantine_dir, quarantine_file)) {
            fputs("Copy complete, but local safety marker remains.\n", stderr);
            result = 1;
        } else quarantine_active = 0;
    }
    if (quarantine_dir >= 0) close(quarantine_dir);
    if (!result) print_pass(request, request->eject ? " and ejected" : "");
    else fputs("NO SUCCESS: see the message above.\n", stderr);
    lease_close(&lease);
    return result;
}

static int run_check_disk(const char *name)
{
    if (!partition_name(name) || select_quarantine_path()) {
        fputs("Refused: run the read-only check with a partition name.\n",
              stderr);
        return 1;
    }
    int result = 1, target = -1, unmounted = 0;
    DiskLease lease = {0};
    lease.session = DASessionCreate(kCFAllocatorDefault);
    if (!lease.session) goto out;
    DASessionScheduleWithRunLoop(lease.session, CFRunLoopGetCurrent(),
                                 kCFRunLoopDefaultMode);
    lease.partition = DADiskCreateFromBSDName(kCFAllocatorDefault,
                                               lease.session, name);
    if (!lease.partition || inspect_partition(&lease, name, 0)) {
        fputs("Refused: target is not an external NTFS partition.\n", stderr);
        goto out;
    }
    char path[1024];
    struct statfs mounted_state;
    if (mounted_path(lease.partition, path, sizeof(path)) != 1 ||
        statfs(path, &mounted_state) || !(mounted_state.f_flags & MNT_RDONLY)) {
        fputs("Refused: mount NTFS read-only before checking.\n", stderr);
        goto out;
    }
    lease.whole = DADiskCopyWholeDisk(lease.partition);
    if (!lease.whole || disk_unmount(lease.whole)) {
        fputs("Read-only check stopped: normal unmount failed; no force used.\n",
              stderr);
        goto out;
    }
    unmounted = 1;
    if (inspect_partition(&lease, name, 1)) {
        fputs("Read-only check stopped: partition identity changed after unmount.\n",
              stderr);
        goto out;
    }
    char device_path[64];
    snprintf(device_path, sizeof(device_path), "/dev/%s", name);
    target = open(device_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (target < 0) {
        perror("Read-only device open failed");
        goto out;
    }
    struct stat target_info;
    uint32_t block_size = 0;
    uint64_t block_count = 0, free_bytes = 0;
    uint32_t warnings = 0;
    if (fstat(target, &target_info)) {
        perror("Read-only device stat failed");
        goto out;
    }
    if (!S_ISBLK(target_info.st_mode)) {
        fputs("Read-only target is not a block device.\n", stderr);
        goto out;
    }
    if (ioctl(target, DKIOCGETBLOCKSIZE, &block_size)) {
        perror("Read-only block-size query failed");
        goto out;
    }
    if (ioctl(target, DKIOCGETBLOCKCOUNT, &block_count)) {
        perror("Read-only block-count query failed");
        goto out;
    }
    if (block_size < 512 || block_size > 65536 ||
        block_count != lease.size / block_size || lease.size % block_size) {
        fprintf(stderr, "Read-only geometry mismatch: block size %u, "
                "count %llu, expected bytes %llu.\n", block_size,
                (unsigned long long)block_count,
                (unsigned long long)lease.size);
        goto out;
    }
    if (inspect_partition(&lease, name, 1)) {
        fputs("Read-only partition identity changed during check.\n", stderr);
        goto out;
    }
    int marker_status = quarantine_status(target, lease.size);
    if (marker_status < 0) {
        fputs("Read-only check could not inspect the local safety marker.\n",
              stderr);
        goto out;
    }
    if (marker_status > 0)
        fputs("Local marker: an earlier OpenHDD transfer did not finish on this "
              "Mac. If the volume checks clean below, the next copy clears it.\n",
              stderr);
    int code = oh_ntfs_safety_preflight(target, lease.size, &free_bytes,
                                        &warnings);
    if (!code && inspect_partition(&lease, name, 1)) code = EIO;
    if (code) {
        print_safety_warnings(warnings);
        if (code == EINPROGRESS)
            fputs("Read-only check found unfinished OpenHDD transfer.\n", stderr);
        else if (!warnings && code == EBUSY)
            fputs("Read-only check inconclusive: volume busy or state uncertain.\n",
                  stderr);
        else if (!warnings)
            fprintf(stderr, "Read-only check failed; code %d.\n", code);
    } else {
        printf("Read-only NTFS safety preflight passed; %llu bytes free. "
               "No writes attempted.\n", (unsigned long long)free_bytes);
        result = 0;
    }
out:
    if (target >= 0 && close(target)) {
        fputs("Read-only device close failed.\n", stderr);
        result = 1;
    }
    if (unmounted && inspect_partition(&lease, name, 1) == 0) {
        if (restore_read_only(lease.partition)) {
            fputs("Read-only check finished, but read-only mount restore failed.\n",
                  stderr);
            result = 1;
        } else {
            fputs("NTFS restored as read-only.\n", stderr);
        }
    } else if (unmounted) {
        fputs("Device changed; automatic remount skipped.\n", stderr);
        result = 1;
    }
    lease_close(&lease);
    return result;
}

static int confirm_disk(DiskLease *lease, const char *name)
{
    if (!isatty(STDIN_FILENO)) return -1;
    char model[256], volume[256];
    if (display_value(lease->whole, kDADiskDescriptionDeviceModelKey,
                      model, sizeof(model)) ||
        display_value(lease->partition, kDADiskDescriptionVolumeNameKey,
                      volume, sizeof(volume))) return -1;
    fprintf(stderr, "External NTFS partition: %s (%llu bytes).\n"
            "Device: %s; volume: %s.\n"
            "OpenHDD adds new files only. If the copy is interrupted, the volume\n"
            "is marked for checking and must be repaired on Windows (chkdsk /f).\n"
            "Type COPY %s to continue: ",
            name, (unsigned long long)lease->size, model, volume, name);
    char response[64], expected[64];
    snprintf(expected, sizeof(expected), "COPY %s\n", name);
    return fgets(response, sizeof(response), stdin) &&
        !strcmp(response, expected) ? 0 : -1;
}

static void usage(void)
{
    fputs("Usage: sudo OpenHDDCopy --check-disk diskXsY\n"
          "       OpenHDDCopy --check-image IMAGE\n"
          "       OpenHDDCopy --image PRIVATE_IMAGE [--dir PATH] SOURCE NAME [SOURCE NAME ...]\n"
          "       sudo OpenHDDCopy --disk diskXsY [--dir PATH] [--yes] [--eject]\n"
          "                        [--owner-uid UID] [--progress FILE]\n"
          "                        SOURCE NAME [SOURCE NAME ...]\n"
          "       ... --image IMAGE | --disk diskXsY [options]\n"
          "           --delete PATH [PATH ...] | --rename PATH NEW_NAME |\n"
          "           --mkdir PARENT_PATH NAME | --move DEST_FOLDER PATH [PATH ...]\n"
          "           (paths relative to the volume root)\n"
          "       --replace: an existing file with the same name is replaced\n"
          "       --manifest FILE instead of SOURCE NAME pairs: NUL-separated\n"
          "           records \"D\" FOLDER and \"F\" SOURCE FOLDER NAME 0|1(replace)\n",
          stderr);
}

/* A path relative to the volume root, NFC, without surrounding slashes. */
static char *relative_copy(const char *value)
{
    while (*value == '/') ++value;
    char *copy = normalized_copy(value);
    if (!copy) return NULL;
    size_t length = strlen(copy);
    while (length && copy[length - 1] == '/') copy[--length] = 0;
    return copy;
}

/* Reads the manifest the app writes for folder copies. Every record is
   validated here, before any disk access. */
static int load_manifest(CopyRequest *request, const char *path)
{
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat state;
    if (fd < 0 || fstat(fd, &state) || !S_ISREG(state.st_mode) ||
        state.st_size < 2 || state.st_size > 256 * 1024 * 1024) {
        if (fd >= 0) close(fd);
        fputs("Refused: manifest missing or too large.\n", stderr);
        return -1;
    }
    size_t size = (size_t)state.st_size;
    char *data = malloc(size + 1);
    size_t got = 0;
    while (data && got < size) {
        ssize_t n = read(fd, data + got, size - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        got += (size_t)n;
    }
    close(fd);
    if (!data || got != size || data[size - 1]) {
        free(data);
        fputs("Refused: manifest unreadable or not NUL-terminated.\n", stderr);
        return -1;
    }
    data[size] = 0;
    request->manifest = data;
    size_t files = 0, folders = 0;
    for (char *cursor = data; cursor < data + size; ) {
        char *kind = cursor;
        cursor += strlen(cursor) + 1;
        size_t fields = !strcmp(kind, "F") ? 4 : !strcmp(kind, "D") ? 1 : 0;
        if (!fields) goto invalid;
        for (size_t i = 0; i < fields; ++i) {
            if (cursor >= data + size) goto invalid;
            cursor += strlen(cursor) + 1;
        }
        if (fields == 4) ++files; else ++folders;
    }
    if (!files && !folders) goto invalid;
    request->sources = calloc(files + 1, sizeof(*request->sources));
    request->names = calloc(files + 1, sizeof(*request->names));
    request->folders = calloc(files + 1, sizeof(*request->folders));
    request->replace = calloc(files + 1, 1);
    request->directories = calloc(folders + 1, sizeof(*request->directories));
    if (!request->sources || !request->names || !request->folders ||
        !request->replace || !request->directories) return -1;
    for (char *cursor = data; cursor < data + size; ) {
        char *kind = cursor;
        cursor += strlen(cursor) + 1;
        if (!strcmp(kind, "D")) {
            char *folder = relative_copy(cursor);
            cursor += strlen(cursor) + 1;
            request->directories[request->directory_count++] = folder;
            if (!folder || !*folder || !oh_ntfs_valid_directory_path(folder)) goto invalid;
            continue;
        }
        size_t i = request->count++;
        request->sources[i] = cursor;
        cursor += strlen(cursor) + 1;
        request->folders[i] = relative_copy(cursor);
        cursor += strlen(cursor) + 1;
        request->names[i] = normalized_copy(cursor);
        cursor += strlen(cursor) + 1;
        const char *replace = cursor;
        cursor += strlen(cursor) + 1;
        if (!request->folders[i] || !request->names[i] ||
            !oh_ntfs_valid_new_name(request->names[i]) ||
            (*request->folders[i] && !oh_ntfs_valid_directory_path(request->folders[i])) ||
            (strcmp(replace, "0") && strcmp(replace, "1"))) {
            fprintf(stderr, "Refused: invalid manifest entry for file %zu. "
                            "No disk access.\n", i + 1);
            return -1;
        }
        request->replace[i] = replace[0] == '1';
    }
    return 0;
invalid:
    fputs("Refused: malformed manifest. No disk access.\n", stderr);
    return -1;
}

/* Each file of a batch stays open until the batch is published; the
   default limit of 256 descriptors is raised as far as allowed. */
static void raise_file_limit(void)
{
    struct rlimit limit;
    if (getrlimit(RLIMIT_NOFILE, &limit)) return;
    rlim_t wanted = limit.rlim_max < OPEN_MAX ? limit.rlim_max : OPEN_MAX;
    if (limit.rlim_cur < wanted) {
        limit.rlim_cur = wanted;
        (void)setrlimit(RLIMIT_NOFILE, &limit);
        (void)getrlimit(RLIMIT_NOFILE, &limit);
    }
    if (limit.rlim_cur < BATCH_FILES + 64)
        batch_limit = limit.rlim_cur > 80 ? (size_t)limit.rlim_cur - 64 : 16;
    #ifdef OPENHDD_TESTING
    const char *forced = getenv("OPENHDD_TEST_BATCH_FILES");
    if (forced && atoi(forced) > 0 && (size_t)atoi(forced) < batch_limit)
        batch_limit = (size_t)atoi(forced);
    #endif
}

static int parse_uid(const char *text, long *out)
{
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (!text || !*text || !end || *end || errno || value > UINT_MAX) return -1;
    *out = (long)value;
    return 0;
}

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--check-disk"))
        return run_check_disk(argv[2]);
    if (argc == 3 && !strcmp(argv[1], "--check-image"))
        return run_check_image(argv[2]);
    if (argc < 5 || (strcmp(argv[1], "--image") && strcmp(argv[1], "--disk"))) {
        usage();
        return 2;
    }
    int disk = !strcmp(argv[1], "--disk");
    #ifdef OPENHDD_TESTING
    if (disk) {
        fputs("Test binary accepts private images only.\n", stderr);
        return 2;
    }
    #endif
    raise_file_limit();
    CopyRequest request = { .target = argv[2], .owner_uid = -1 };
    const char *manifest = NULL;
    const char *sudo_uid = getenv("SUDO_UID");
    if (sudo_uid && parse_uid(sudo_uid, &request.owner_uid)) request.owner_uid = -1;
    int index = 3;
    for (; index < argc && !strncmp(argv[index], "--", 2); ++index) {
        const char *option = argv[index];
        if (!strcmp(option, "--yes") && disk) request.assume_confirmed = 1;
        else if (!strcmp(option, "--eject") && disk) request.eject = 1;
        else if (!strcmp(option, "--replace")) request.replace_all = 1;
        else if (!strcmp(option, "--manifest") && index + 1 < argc && !manifest)
            manifest = argv[++index];
        else if (!strcmp(option, "--dir") && index + 1 < argc && !request.directory) {
            request.directory = normalized_copy(argv[++index]);
            if (!request.directory) { usage(); return 2; }
        } else if (!strcmp(option, "--progress") && index + 1 < argc)
            request.progress_path = argv[++index];
        else if (!strcmp(option, "--owner-uid") && disk && index + 1 < argc) {
            if (parse_uid(argv[++index], &request.owner_uid)) { usage(); return 2; }
        } else if (!strcmp(option, "--delete")) { request.edit_kind = OH_EDIT_DELETE; ++index; break; }
        else if (!strcmp(option, "--rename")) { request.edit_kind = OH_EDIT_RENAME; ++index; break; }
        else if (!strcmp(option, "--mkdir")) { request.edit_kind = OH_EDIT_MKDIR; ++index; break; }
        else if (!strcmp(option, "--move")) { request.edit_kind = OH_EDIT_MOVE; ++index; break; }
        else { usage(); request_free(&request); return 2; }
    }
    int remaining = argc - index;
    if (request.edit_kind) {
        int kind = request.edit_kind;
        size_t wanted = kind == OH_EDIT_DELETE || kind == OH_EDIT_MOVE ? 0 : 2;
        if (remaining < (kind == OH_EDIT_MOVE ? 2 : 1) ||
            (wanted && remaining != (int)wanted) || manifest || request.replace_all) {
            usage(); request_free(&request); return 2;
        }
        request.edit_count = kind == OH_EDIT_DELETE ? (size_t)remaining :
                             kind == OH_EDIT_MOVE ? (size_t)remaining - 1 : 1;
        request.edits = calloc(request.edit_count, sizeof(*request.edits));
        request.edit_strings = calloc((size_t)remaining, sizeof(char *));
        if (!request.edits || !request.edit_strings) { request_free(&request); return 1; }
        for (int i = 0; i < remaining; ++i) {
            /* paths are relative to the root */
            char *copy = relative_copy(argv[index + i]);
            if (!copy) { request_free(&request); return 2; }
            request.edit_strings[request.edit_string_count++] = copy;
        }
        for (size_t i = 0; i < request.edit_count; ++i) {
            request.edits[i].kind = kind;
            if (kind == OH_EDIT_DELETE) {
                request.edits[i].path = request.edit_strings[i];
            } else if (kind == OH_EDIT_MOVE) {
                request.edits[i].path = request.edit_strings[i + 1];
                request.edits[i].name = request.edit_strings[0];
            } else {
                request.edits[i].path = request.edit_strings[0];
                request.edits[i].name = request.edit_strings[1];
            }
        }
        int result = disk ? run_disk(&request) : run_image(&request);
        request_free(&request);
        return result;
    }
    if (manifest) {
        if (remaining || request.directory || request.replace_all) {
            usage(); request_free(&request); return 2;
        }
        int result = load_manifest(&request, manifest) ? 2 :
            disk ? run_disk(&request) : run_image(&request);
        request_free(&request);
        return result;
    }
    if (remaining < 2 || remaining % 2) { usage(); request_free(&request); return 2; }
    request.count = (size_t)remaining / 2;
    request.sources = calloc(request.count, sizeof(*request.sources));
    request.names = calloc(request.count, sizeof(*request.names));
    if (!request.sources || !request.names) { request_free(&request); return 1; }
    for (size_t i = 0; i < request.count; ++i) {
        request.sources[i] = argv[index + 2 * (int)i];
        request.names[i] = normalized_copy(argv[index + 2 * (int)i + 1]);
        if (!request.names[i] || !oh_ntfs_valid_new_name(request.names[i])) {
            fprintf(stderr, "Refused: invalid new file name for item %zu. "
                            "No disk access.\n", i + 1);
            request_free(&request);
            return 2;
        }
    }
    if (request.directory && !oh_ntfs_valid_directory_path(request.directory)) {
        fputs("Refused: invalid destination folder. No disk access.\n", stderr);
        request_free(&request);
        return 2;
    }
    int result = disk ? run_disk(&request) : run_image(&request);
    request_free(&request);
    return result;
}
