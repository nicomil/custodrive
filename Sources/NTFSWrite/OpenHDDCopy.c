#include "WriteEngine.h"
#include "OpenHDDNTFS.h"

#include <CoreFoundation/CoreFoundation.h>
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOKitLib.h>
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
#include <sys/stat.h>
#include <unistd.h>

/* A local marker survives process death even if NTFS lost its pending name
   during the last metadata sync. It is cleared only after normal eject. */
static const char *quarantine_path = "/private/var/db/openhdd";

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
        int parent = open("/private/var/db",
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
            "EXPERIMENTAL: a disconnected test drive developed NTFS bitmap errors.\n"
            "Only use a disposable drive with a verified backup.\n"
            "Type COPY %s to continue: ",
            name, (unsigned long long)lease->size, model, volume, name);
    char response[64], expected[64];
    snprintf(expected, sizeof(expected), "COPY %s\n", name);
    return fgets(response, sizeof(response), stdin) &&
        !strcmp(response, expected) ? 0 : -1;
}

static int run_image(const char *path, const char *source_path,
                     const char *name)
{
    struct stat before, after, source_info;
    int result = 1, stage = 0;
    uint32_t warnings = 0;
    if (lstat(path, &before) || !private_image(path, &before)) {
        fputs("Refused: target must be a private regular image.\n", stderr);
        return 1;
    }
    int target = open(path, O_RDWR | O_EXCL | O_NOFOLLOW | O_CLOEXEC);
    int source = open(source_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (target < 0 || source < 0 || fstat(target, &after) ||
        fstat(source, &source_info) || !S_ISREG(source_info.st_mode) ||
        before.st_dev != after.st_dev || before.st_ino != after.st_ino ||
        before.st_size != after.st_size ||
        (source_info.st_dev == after.st_dev &&
         source_info.st_ino == after.st_ino)) {
        fputs("Refused: image or source changed.\n", stderr);
        goto out;
    }
    int code = oh_copy_new_file(target, (uint64_t)after.st_size, 0,
                                source, name, &stage, &warnings);
    if (code == EINPROGRESS)
        fputs("Refused: unfinished OpenHDD transfer found. Inspect image.\n", stderr);
    else if (code) {
        print_safety_warnings(warnings);
        fprintf(stderr, "Copy failed at stage %d; code %d. Inspect image.\n",
                stage, code);
    } else result = 0;
out:
    if (source >= 0) close(source);
    if (target >= 0 && close(target)) {
        fputs("Image close failed; no success reported.\n", stderr);
        result = 1;
    }
    if (!result) puts("PASS: image copy verified and temporary name removed.");
    return result;
}

static int run_disk(const char *name, const char *source_path,
                    const char *file_name)
{
    const char *sudo_uid = getenv("SUDO_UID");
    char *end = NULL;
    errno = 0;
    unsigned long invoking_uid = sudo_uid ? strtoul(sudo_uid, &end, 10) : 0;
    if (geteuid() != 0 || !partition_name(name) || !sudo_uid ||
        !*sudo_uid || !end || *end || errno || invoking_uid > UINT_MAX) {
        fputs("Refused: use sudo and a partition name such as disk4s1.\n", stderr);
        return 1;
    }
    int result = 1, stage = 0, target = -1, source = -1;
    int quarantine_dir = -1, quarantine_active = 0;
    char quarantine_file[80] = {0};
    uint32_t warnings = 0;
    int had_mount = 0, unmounted = 0;
    DiskLease lease = {0};
    lease.session = DASessionCreate(kCFAllocatorDefault);
    if (!lease.session) goto out;
    DASessionScheduleWithRunLoop(lease.session, CFRunLoopGetCurrent(),
                                 kCFRunLoopDefaultMode);
    lease.partition = DADiskCreateFromBSDName(kCFAllocatorDefault,
                                               lease.session, name);
    if (!lease.partition || inspect_partition(&lease, name, 0)) goto out;
    char existing_path[1024];
    had_mount = mounted_path(lease.partition, existing_path,
                             sizeof(existing_path)) == 1;
    lease.whole = DADiskCopyWholeDisk(lease.partition);
    if (!lease.whole || confirm_disk(&lease, name)) goto out;
    if (disk_unmount(lease.whole)) {
        fputs("Refused: normal unmount failed; no force used.\n", stderr);
        goto out;
    }
    unmounted = 1;
    if (disk_claim(&lease) || inspect_partition(&lease, name, 1)) {
        fputs("Refused: exclusive claim or device identity failed.\n", stderr);
        goto out;
    }
    char path[64];
    snprintf(path, sizeof(path), "/dev/%s", name);
    target = open(path, O_RDWR | O_EXCL | O_NOFOLLOW | O_CLOEXEC);
    source = open(source_path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat target_info, source_info;
    uint32_t block_size = 0;
    uint64_t block_count = 0;
    if (target < 0 || source < 0 || fstat(target, &target_info) ||
        fstat(source, &source_info) || !S_ISBLK(target_info.st_mode) ||
        !S_ISREG(source_info.st_mode) ||
        source_info.st_uid != (uid_t)invoking_uid ||
        ioctl(target, DKIOCGETBLOCKSIZE, &block_size) ||
        ioctl(target, DKIOCGETBLOCKCOUNT, &block_count) ||
        block_size < 512 || block_size > 65536 ||
        block_count != lease.size / block_size ||
        lease.size % block_size || inspect_partition(&lease, name, 1)) {
        fputs("Refused: device access, geometry or identity failed.\n", stderr);
        goto out;
    }
    int marker_status = quarantine_begin(target, lease.size, &quarantine_dir,
                                         quarantine_file,
                                         sizeof(quarantine_file));
    if (marker_status) {
        if (marker_status == EINPROGRESS)
            fputs("Refused: previous OpenHDD transfer unresolved on this Mac. "
                  "Check the volume on Windows before another write.\n", stderr);
        else
            fputs("Refused: local safety marker could not be secured. "
                  "No NTFS write started.\n", stderr);
        goto out;
    }
    quarantine_active = 1;
    int code = oh_copy_new_file(target, lease.size, 1,
                                source, file_name, &stage, &warnings);
    if (code) {
        if (stage == 1 && !quarantine_clear(quarantine_dir, quarantine_file))
            quarantine_active = 0; /* preflight never enters RW mount */
        if (code == EINPROGRESS)
            fputs("Refused: unfinished OpenHDD transfer found. "
                  "Check volume on Windows; no new copy started.\n", stderr);
        else {
            print_safety_warnings(warnings);
            if (!warnings && stage == 1 && code == EBUSY)
                fputs("Preflight refused: volume busy or safety state uncertain; "
                      "no writes started.\n", stderr);
            fprintf(stderr, "Copy failed at stage %d; code %d. "
                            "Do not trust destination; check with Windows.\n",
                    stage, code);
        }
        goto out;
    }
    if (inspect_partition(&lease, name, 1)) {
        fputs("Copy verified, but device identity changed. No success reported.\n",
              stderr);
        goto out;
    }
    result = 0;
out:
    if (source >= 0) close(source);
    if (target >= 0 && close(target)) {
        fputs("Device close failed; no success reported.\n", stderr);
        result = 1;
    }
    if (lease.claimed) {
        int same_device = inspect_partition(&lease, name, 1) == 0;
        DADiskUnclaim(lease.whole);
        lease.claimed = 0;
        if (!same_device) {
            fputs("Device identity changed; automatic eject skipped.\n", stderr);
            result = 1;
        } else if (disk_unmount(lease.whole) || disk_eject(lease.whole)) {
            fputs("Eject failed; keep drive connected and inspect it.\n", stderr);
            result = 1;
        }
    } else if (unmounted && had_mount && inspect_partition(&lease, name, 1) == 0) {
        if (restore_read_only(lease.partition))
            fputs("Previous read-only mount could not be restored.\n", stderr);
        else
            fputs("Previous read-only mount restored.\n", stderr);
    }
    if (!result && quarantine_active) {
        if (quarantine_clear(quarantine_dir, quarantine_file)) {
            fputs("Eject succeeded, but local safety marker remains uncertain.\n",
                  stderr);
            result = 1;
        } else quarantine_active = 0;
    }
    if (quarantine_dir >= 0) close(quarantine_dir);
    if (!result) puts("PASS: copied, independently verified and ejected.");
    else fputs("NO SUCCESS: drive may need Windows chkdsk.\n", stderr);
    lease_close(&lease);
    return result;
}

static int run_check_disk(const char *name)
{
    if (geteuid() != 0 || !partition_name(name)) {
        fputs("Refused: run read-only check with sudo and a partition name.\n",
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
    if (marker_status) {
        fputs(marker_status > 0 ?
              "Read-only check found an unresolved local OpenHDD transfer.\n" :
              "Read-only check could not inspect the local safety marker.\n",
              stderr);
        goto out;
    }
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

int main(int argc, char **argv)
{
    if (argc == 3 && !strcmp(argv[1], "--check-disk"))
        return run_check_disk(argv[2]);
    #ifdef OPENHDD_TESTING
    if (argc == 5 && !strcmp(argv[1], "--disk")) {
        fputs("Test binary accepts private images only.\n", stderr);
        return 2;
    }
    #endif
    if (argc != 5 ||
        (strcmp(argv[1], "--image") && strcmp(argv[1], "--disk"))) {
        fputs("Usage: sudo OpenHDDCopy --check-disk diskXsY\n"
              "       OpenHDDCopy --image PRIVATE_IMAGE SOURCE NEW_NAME\n"
              "       sudo OpenHDDCopy --disk diskXsY SOURCE NEW_NAME\n",
              stderr);
        return 2;
    }
    if (!oh_ntfs_valid_new_name(argv[4])) {
        fputs("Refused: invalid new file name. No disk access.\n", stderr);
        return 2;
    }
    if (!strcmp(argv[1], "--image"))
        return run_image(argv[2], argv[3], argv[4]);
    return run_disk(argv[2], argv[3], argv[4]);
}
