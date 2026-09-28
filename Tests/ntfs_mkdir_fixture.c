/*
 * Test fixture helper: creates nested directories inside a disposable NTFS
 * image with NTFS-3G, so the copy engine can be exercised on subfolders.
 * Usage: ntfs_mkdir_fixture IMAGE "Dir A/Dir B"
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

int main(int argc, char **argv)
{
    if (argc != 3) {
        fprintf(stderr, "usage: %s IMAGE PATH\n", argv[0]);
        return 2;
    }
    ntfs_log_set_handler(ntfs_log_handler_null);
    ntfs_volume *volume = ntfs_mount(argv[1], 0);
    if (!volume) { perror("mount"); return 1; }
    ntfs_inode *parent = ntfs_inode_open(volume, FILE_root);
    char *path = strdup(argv[2]), *cursor = path, *component;
    int status = parent && path ? 0 : 1;
    while (!status && (component = strsep(&cursor, "/"))) {
        if (!*component) continue;
        ntfschar *wide = NULL;
        int length = ntfs_mbstoucs(component, &wide);
        ntfs_inode *child = length > 0 ?
            ntfs_create(parent, const_cpu_to_le32(0), wide, (u8)length, S_IFDIR) :
            NULL;
        free(wide);
        if (!child) { perror("create"); status = 1; break; }
        ntfs_inode_close(parent);
        parent = child;
    }
    if (parent && ntfs_inode_close(parent)) status = 1;
    if (ntfs_umount(volume, FALSE)) status = 1;
    free(path);
    return status;
}
