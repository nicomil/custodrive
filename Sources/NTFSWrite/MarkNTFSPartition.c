/* Changes only the MBR partition type after mkntfs has created a valid volume. */
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <unistd.h>

static uint32_t le32(const unsigned char *bytes)
{
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
           (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}

static uint64_t number(const char *text)
{
    char *end = NULL;
    errno = 0;
    unsigned long long value = strtoull(text, &end, 10);
    return errno || !text[0] || !end || *end ? 0 : (uint64_t)value;
}

int main(int argc, char **argv)
{
    if (argc != 5) {
        fputs("Usage: MarkNTFSPartition DEVICE WHOLE_BYTES START_SECTORS PARTITION_SECTORS\n", stderr);
        return 2;
    }
    uint64_t whole = number(argv[2]), start = number(argv[3]);
    uint64_t sectors = number(argv[4]);
    if (!whole || !start || !sectors || whole % 512 ||
        start > UINT32_MAX || sectors > UINT32_MAX ||
        start + sectors > whole / 512) return 2;

    int fd = open(argv[1], O_RDWR | O_EXCL | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) { perror("Open refused"); return 1; }
    int result = 1;
    struct stat info;
    unsigned char mbr[512], boot[512];
    if (fstat(fd, &info) || (!S_ISBLK(info.st_mode) &&
                            !S_ISREG(info.st_mode))) goto out;
    if (S_ISREG(info.st_mode)) {
        if ((uint64_t)info.st_size != whole) goto out;
    } else {
        uint32_t block_size = 0;
        uint64_t block_count = 0;
        if (ioctl(fd, DKIOCGETBLOCKSIZE, &block_size) ||
            ioctl(fd, DKIOCGETBLOCKCOUNT, &block_count) ||
            block_size != 512 || block_count != whole / 512) goto out;
    }
    if (pread(fd, mbr, sizeof(mbr), 0) != sizeof(mbr) ||
        pread(fd, boot, sizeof(boot), (off_t)(start * 512)) != sizeof(boot) ||
        mbr[510] != 0x55 || mbr[511] != 0xaa ||
        boot[510] != 0x55 || boot[511] != 0xaa ||
        memcmp(boot + 3, "NTFS    ", 8) ||
        boot[11] != 0 || boot[12] != 2 ||
        (mbr[450] != 0x0b && mbr[450] != 0x0c) ||
        le32(mbr + 454) != start || le32(mbr + 458) != sectors)
        goto out;
    for (int entry = 1; entry < 4; ++entry)
        if (mbr[446 + entry * 16 + 4]) goto out;

    mbr[450] = 0x07;
    if (pwrite(fd, mbr, sizeof(mbr), 0) != sizeof(mbr) || fsync(fd))
        goto out;
    if (S_ISBLK(info.st_mode) && ioctl(fd, DKIOCSYNCHRONIZECACHE))
        goto out;
    result = 0;
out:
    if (close(fd)) result = 1;
    if (result) fputs("MBR type update failed; no success reported.\n", stderr);
    return result;
}
