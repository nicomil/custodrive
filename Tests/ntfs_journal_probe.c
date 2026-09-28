/*
 * Read-only $LogFile inspection for the journal gate.
 *
 * This is deliberately not a transaction writer.  G1 is not passed, so any
 * write-shaped request is rejected before opening the image.  The program
 * only parses structures already present in an NTFS image and reports the
 * evidence needed to continue the research.
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/logfile.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/volume.h>

enum {
    MIN_PAGE_SIZE = 512,
    MAX_PAGE_SIZE = 1024 * 1024,
    RESTART_PAGE_COUNT = 2,
    LOG_PAGE_HEADER_SIZE = sizeof(RECORD_PAGE_HEADER)
};

typedef struct {
    int fd;
    uint64_t size;
    uint64_t position;
} ReadOnlyImage;

static uint64_t write_attempts;

static ReadOnlyImage *image_of(struct ntfs_device *device)
{
    return (ReadOnlyImage *)device->d_private;
}

static int image_open(struct ntfs_device *device, int flags)
{
    if ((flags & O_ACCMODE) != O_RDONLY) {
        errno = EROFS;
        return -1;
    }
    NDevSetReadOnly(device);
    NDevSetOpen(device);
    return 0;
}

static int image_close(struct ntfs_device *device)
{
    NDevClearOpen(device);
    return 0;
}

static s64 image_seek(struct ntfs_device *device, s64 offset, int whence)
{
    ReadOnlyImage *image = image_of(device);
    uint64_t base;

    if (whence == SEEK_SET) base = 0;
    else if (whence == SEEK_CUR) base = image->position;
    else if (whence == SEEK_END) base = image->size;
    else { errno = EINVAL; return -1; }

    if (base > INT64_MAX ||
        (offset < 0 && (uint64_t)(-(offset + 1)) + 1 > base) ||
        (offset > 0 && (uint64_t)offset > image->size - base)) {
        errno = EINVAL;
        return -1;
    }
    image->position = offset < 0
        ? base - ((uint64_t)(-(offset + 1)) + 1)
        : base + (uint64_t)offset;
    return (s64)image->position;
}

static s64 image_pread(struct ntfs_device *device, void *buffer,
                       s64 count, s64 offset)
{
    ReadOnlyImage *image = image_of(device);
    if (count < 0 || offset < 0 || (uint64_t)offset > image->size ||
        (uint64_t)count > image->size - (uint64_t)offset) {
        errno = EINVAL;
        return -1;
    }
    size_t done = 0;
    while (done < (size_t)count) {
        ssize_t n = pread(image->fd, (unsigned char *)buffer + done,
                          (size_t)count - done, (off_t)offset + (off_t)done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { if (!n) errno = EIO; return -1; }
        done += (size_t)n;
    }
    return count;
}

static s64 image_read(struct ntfs_device *device, void *buffer, s64 count)
{
    ReadOnlyImage *image = image_of(device);
    s64 result = image_pread(device, buffer, count, (s64)image->position);
    if (result > 0) image->position += (uint64_t)result;
    return result;
}

static s64 image_write(struct ntfs_device *device, const void *buffer, s64 count)
{
    (void)device;
    (void)buffer;
    (void)count;
    ++write_attempts;
    errno = EROFS;
    return -1;
}

static s64 image_pwrite(struct ntfs_device *device, const void *buffer,
                        s64 count, s64 offset)
{
    (void)offset;
    return image_write(device, buffer, count);
}

static int image_sync(struct ntfs_device *device)
{
    (void)device;
    return 0;
}

static int image_stat(struct ntfs_device *device, struct stat *out)
{
    ReadOnlyImage *image = image_of(device);
    if (image->size > INT64_MAX) { errno = EOVERFLOW; return -1; }
    memset(out, 0, sizeof(*out));
    out->st_mode = S_IFREG | 0400;
    out->st_size = (off_t)image->size;
    out->st_blksize = 512;
    out->st_blocks = (blkcnt_t)(image->size / 512);
    return 0;
}

static int image_ioctl(struct ntfs_device *device, unsigned long request,
                       void *argument)
{
    (void)device;
    (void)request;
    (void)argument;
    errno = ENOTTY;
    return -1;
}

static struct ntfs_device_operations read_only_operations = {
    .open = image_open,
    .close = image_close,
    .seek = image_seek,
    .read = image_read,
    .write = image_write,
    .pread = image_pread,
    .pwrite = image_pwrite,
    .sync = image_sync,
    .stat = image_stat,
    .ioctl = image_ioctl
};

static int read_attribute(ntfs_attr *attribute, s64 offset, void *buffer,
                          s64 length)
{
    if (offset < 0 || length < 0 || offset > attribute->data_size ||
        length > attribute->data_size - offset ||
        ntfs_attr_pread(attribute, offset, length, buffer) != length) {
        errno = EIO;
        return -1;
    }
    return 0;
}

static int power_of_two_u32(uint32_t value)
{
    return value >= MIN_PAGE_SIZE && value <= MAX_PAGE_SIZE &&
           (value & (value - 1)) == 0;
}

static void print_string(const char *key, const char *value, int *first)
{
    printf("%s\"%s\":\"%s\"", *first ? "" : ",", key, value);
    *first = 0;
}

static void print_u64(const char *key, uint64_t value, int *first)
{
    printf("%s\"%s\":%" PRIu64, *first ? "" : ",", key, value);
    *first = 0;
}

static void print_bool(const char *key, int value, int *first)
{
    printf("%s\"%s\":%s", *first ? "" : ",", key, value ? "true" : "false");
    *first = 0;
}

static int inspect_log(ntfs_volume *volume, int *inspection_ok)
{
    ntfs_inode *log_inode = NULL;
    ntfs_attr *log_data = NULL;
    RESTART_PAGE_HEADER *restart = NULL;
    unsigned char *page = NULL;
    uint32_t system_page_size = 0;
    uint32_t log_page_size = 0;
    uint64_t record_pages = 0;
    uint64_t nonempty_pages = 0;
    uint64_t page_count = 0;
    int first = 1;
    int status = -1;

    log_inode = ntfs_inode_open(volume, FILE_LogFile);
    if (!log_inode) goto out;
    log_data = ntfs_attr_open(log_inode, AT_DATA, AT_UNNAMED, 0);
    if (!ntfs_check_logfile(log_data, &restart) || !restart) goto out;
    system_page_size = le32_to_cpu(restart->system_page_size);
    log_page_size = le32_to_cpu(restart->log_page_size);
    if (!power_of_two_u32(system_page_size) ||
        !power_of_two_u32(log_page_size)) goto out;
    *inspection_ok = ntfs_is_logfile_clean(log_data, restart) ? 1 : 0;

    RESTART_AREA *area = (RESTART_AREA *)((unsigned char *)restart +
        le16_to_cpu(restart->restart_area_offset));
    page = malloc(log_page_size);
    if (!page) goto out;

    page_count = (uint64_t)log_data->data_size / log_page_size;
    for (uint64_t page_index = RESTART_PAGE_COUNT;
         page_index < page_count; ++page_index) {
        s64 offset = (s64)(page_index * (uint64_t)log_page_size);
        if (read_attribute(log_data, offset, page, LOG_PAGE_HEADER_SIZE)) goto out;
        RECORD_PAGE_HEADER *header = (RECORD_PAGE_HEADER *)page;
        if (header->magic == magic_RCRD) {
            ++record_pages;
            uint16_t usa_count = le16_to_cpu(header->usa_count);
            if (usa_count) ++nonempty_pages;
        }
    }

    printf("{");
    print_string("schema", "openhdd.ntfs-journal-inspection.v1", &first);
    print_string("inspection", *inspection_ok ? "PASS" : "FAIL", &first);
    print_string("writer", "REFUSED_G1_NOT_PASSED", &first);
    print_string("g1", "INCONCLUDENTE", &first);
    print_u64("log_data_size", (uint64_t)log_data->data_size, &first);
    print_u64("system_page_size", system_page_size, &first);
    print_u64("log_page_size", log_page_size, &first);
    print_u64("restart_page_count", RESTART_PAGE_COUNT, &first);
    print_u64("record_pages", record_pages, &first);
    print_u64("record_pages_with_usa", nonempty_pages, &first);
    print_u64("scanned_pages", page_count, &first);
    print_bool("zero_write_attempts", write_attempts == 0, &first);
    print_u64("current_lsn", (uint64_t)sle64_to_cpu(area->current_lsn), &first);
    print_u64("restart_flags", le16_to_cpu(area->flags), &first);
    print_u64("log_clients", le16_to_cpu(area->log_clients), &first);
    print_u64("file_size", (uint64_t)sle64_to_cpu(area->file_size), &first);
    print_u64("log_record_header_length",
              le16_to_cpu(area->log_record_header_length), &first);
    print_u64("log_page_data_offset", le16_to_cpu(area->log_page_data_offset), &first);
    printf("}\n");
    status = 0;

out:
    free(page);
    free(restart);
    if (log_data) ntfs_attr_close(log_data);
    if (log_inode) ntfs_inode_close(log_inode);
    return status;
}

static int inspect_image(const char *path)
{
    struct stat before;
    struct stat after;
    int fd = -1;
    ReadOnlyImage image = {0};
    struct ntfs_device *device = NULL;
    ntfs_volume *volume = NULL;
    int inspection_ok = 0;
    int result = 2;

    if (lstat(path, &before) || !S_ISREG(before.st_mode) ||
        before.st_nlink != 1 || before.st_size < 4096) {
        fprintf(stderr, "REFUSED: image must be one regular private file\n");
        return 77;
    }
    fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0 || fstat(fd, &after) || !S_ISREG(after.st_mode) ||
        after.st_dev != before.st_dev || after.st_ino != before.st_ino ||
        after.st_size != before.st_size || after.st_size > INT64_MAX) {
        fprintf(stderr, "REFUSED: image identity changed or is not regular\n");
        if (fd >= 0) close(fd);
        return 77;
    }

    image.fd = fd;
    image.size = (uint64_t)after.st_size;
    ntfs_log_set_handler(ntfs_log_handler_null);
    device = ntfs_device_alloc("OpenHDD journal probe", 0,
                               &read_only_operations, &image);
    if (!device) goto out;
    volume = ntfs_device_mount(device, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!volume) goto out;
    if (inspect_log(volume, &inspection_ok)) goto out;
    result = inspection_ok ? 0 : 2;

out:
    if (volume) {
        ntfs_umount(volume, FALSE);
        device = NULL; /* ntfs_umount owns/frees mounted device. */
    }
    if (device) ntfs_device_free(device);
    close(fd);
    if (result != 0)
        fprintf(stderr, "INCONCLUDENTE: read-only journal inspection failed\n");
    return result;
}

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "usage: ntfs_journal_probe IMAGE\n");
        return 64;
    }
    if (!strcmp(argv[1], "--write") || !strcmp(argv[1], "--transaction")) {
        fprintf(stderr, "REFUSED: G1 not passed; transaction writer is disabled\n");
        return 77;
    }
    return inspect_image(argv[1]);
}
