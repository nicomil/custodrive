#include "OpenHDDNTFS.h"

#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static int64_t image_read(void *opaque, uint64_t offset, void *buffer,
                          uint64_t length)
{
    return pread(*(int *)opaque, buffer, (size_t)length, (off_t)offset);
}

static int visit(void *opaque, const char *name, const OHNTFSItem *item)
{
    int *count = opaque;
    ++*count;
    assert(name[0]);
    assert(item->kind == 1 || item->kind == 2);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 3 && argc != 4) return 2;
    int fd = open(argv[1], O_RDONLY);
    assert(fd >= 0);
    struct stat st;
    assert(fstat(fd, &st) == 0);
    OHNTFSVolume *volume = NULL;
    uint32_t warnings = 0;
    int error = oh_ntfs_open(image_read, &fd, (uint64_t)st.st_size,
                             &volume, &warnings);
    if (strcmp(argv[2], "--reject") == 0) {
        assert(error != 0);
        assert(volume == NULL);
        assert(oh_ntfs_total_write_attempts() == 0);
        close(fd);
        return 0;
    }
    if (error) { fprintf(stderr, "open: %d\n", error); return 1; }
    if (argc == 4) {
        if (strcmp(argv[3], "--expect-dirty") == 0)
            assert((warnings & OH_NTFS_WARNING_DIRTY) != 0);
        else if (strcmp(argv[3], "--expect-hibernated") == 0)
            assert((warnings & OH_NTFS_WARNING_HIBERNATED_OR_UNCERTAIN) != 0);
        else return 2;
    }
    OHNTFSItem root;
    assert(oh_ntfs_stat(volume, 5, &root) == 0);
    assert(root.kind == 2);
    int count = 0;
    assert(oh_ntfs_list(volume, 5, visit, &count) == 0);
    assert(count >= 1);
    OHNTFSItem known;
    assert(oh_ntfs_lookup(volume, 5, "known.txt", &known) == 0);
    assert(known.kind == 1);
    assert(known.size == strlen("OpenHDD safe read test\n"));
    char contents[64] = {0};
    assert(oh_ntfs_read(volume, known.inode, 0, contents, known.size) ==
           (int64_t)known.size);
    assert(strcmp(contents, "OpenHDD safe read test\n") == 0);
    assert(oh_ntfs_read(volume, known.inode, known.size, contents,
                        sizeof(contents)) == 0);
    OHNTFSItem empty;
    assert(oh_ntfs_lookup(volume, 5, "empty.txt", &empty) == 0);
    assert(empty.size == 0);
    OHNTFSItem unicode;
    assert(oh_ntfs_lookup(volume, 5, "café.txt", &unicode) == 0);
    assert(unicode.size == 5);
    memset(contents, 0, sizeof(contents));
    assert(oh_ntfs_read(volume, unicode.inode, 0, contents, 5) == 5);
    assert(memcmp(contents, "café", 5) == 0);
    OHNTFSItem large;
    assert(oh_ntfs_lookup(volume, 5, "large.bin", &large) == 0);
    assert(large.size == 2 * 1024 * 1024);
    int source = open(argv[2], O_RDONLY);
    assert(source >= 0);
    char actual[65536];
    char expected[65536];
    for (uint64_t offset = 0; offset < large.size; offset += sizeof(actual)) {
        assert(oh_ntfs_read(volume, large.inode, offset, actual,
                            sizeof(actual)) == sizeof(actual));
        assert(pread(source, expected, sizeof(expected), (off_t)offset) ==
               sizeof(expected));
        assert(memcmp(actual, expected, sizeof(actual)) == 0);
    }
    close(source);
    assert(oh_ntfs_write_attempts(volume) == 0);
    assert(oh_ntfs_total_write_attempts() == 0);
    printf("root entries: %d; warnings: %u; block writes: %llu\n",
           count, warnings, (unsigned long long)oh_ntfs_write_attempts(volume));
    oh_ntfs_close(volume);
    assert(oh_ntfs_total_write_attempts() == 0);
    close(fd);
    return 0;
}
