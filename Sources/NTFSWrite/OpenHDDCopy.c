#include "WriteEngine.h"

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

static int confirm_disk(const char *name, uint64_t size)
{
    if (!isatty(STDIN_FILENO)) return -1;
    fprintf(stderr, "External NTFS partition: %s (%llu bytes).\n"
            "Only use a disposable drive with a verified backup.\n"
            "Type COPY %s to continue: ",
            name, (unsigned long long)size, name);
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
                                source, name, &stage);
    if (code == EINPROGRESS)
        fputs("Refused: unfinished OpenHDD transfer found. Inspect image.\n", stderr);
    else if (code)
        fprintf(stderr, "Copy failed at stage %d; code %d. Inspect image.\n",
                stage, code);
    else result = 0;
out:
    if (source >= 0) close(source);
    if (target >= 0 && close(target)) {
        fputs("Image close failed; no success reported.\n", stderr);
        result = 1;
    }
    if (!result) puts("PASS: image copy verified; pending hard link remains.");
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
    if (!lease.whole || confirm_disk(name, lease.size)) goto out;
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
    int code = oh_copy_new_file(target, lease.size, 1,
                                source, file_name, &stage);
    if (code) {
        if (code == EINPROGRESS)
            fputs("Refused: unfinished OpenHDD transfer found. "
                  "Check volume on Windows; no new copy started.\n", stderr);
        else
            fprintf(stderr, "Copy failed at stage %d; code %d. "
                            "Do not trust destination; check with Windows.\n",
                    stage, code);
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
    if (!result) puts("PASS: copied, independently verified and ejected. "
                      "Pending hard link remains.");
    else fputs("NO SUCCESS: drive may need Windows chkdsk.\n", stderr);
    lease_close(&lease);
    return result;
}

int main(int argc, char **argv)
{
    if (argc != 5 ||
        (strcmp(argv[1], "--image") && strcmp(argv[1], "--disk"))) {
        fputs("Usage: OpenHDDCopy --image PRIVATE_IMAGE SOURCE NEW_NAME\n"
              "       sudo OpenHDDCopy --disk diskXsY SOURCE NEW_NAME\n",
              stderr);
        return 2;
    }
    if (!strcmp(argv[1], "--image"))
        return run_image(argv[2], argv[3], argv[4]);
    return run_disk(argv[2], argv[3], argv[4]);
}
