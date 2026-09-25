/* Image-only experiment. This program cannot open block or character devices. */
#include "OpenHDDNTFS.h"

#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <locale.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

enum { CHUNK = 65536 };

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
    if (status) fprintf(stderr, "write or verification failed; stage=%d errno=%d; image needs inspection\n", stage, errno);
    else puts("PASS: image-only write, close, read-only reopen and SHA-256 verification");
    return status;
}
