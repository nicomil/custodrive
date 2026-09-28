#ifndef OPEN_HDD_NTFS_H
#define OPEN_HDD_NTFS_H

#include <stdint.h>
#include <stddef.h>

typedef struct OHNTFSVolume OHNTFSVolume;
typedef int64_t (*OHNTFSReadBlocks)(void *context, uint64_t offset,
                                    void *buffer, uint64_t length);

typedef struct {
    uint64_t inode;
    uint64_t size;
    uint64_t allocated_size;
    int64_t created_ns;
    int64_t modified_ns;
    uint32_t kind; /* 1 = regular file, 2 = directory */
    uint32_t hard_link_count;
    uint32_t special; /* 1 when reparse point or encrypted: never traversed */
} OHNTFSItem;

typedef int (*OHNTFSEntryCallback)(void *context, const char *utf8_name,
                                    const OHNTFSItem *item);

enum {
    OH_NTFS_WARNING_DIRTY = 1u << 0,
    OH_NTFS_WARNING_HIBERNATED_OR_UNCERTAIN = 1u << 1,
    OH_NTFS_WARNING_JOURNAL_SUSPECT = 1u << 2,
    OH_NTFS_WARNING_TXF_REWRITE_RISK = 1u << 3
};

/* The callback must only read. It must return the byte count or -1 with errno. */
int oh_ntfs_open(OHNTFSReadBlocks read_blocks, void *context,
                 uint64_t device_size, OHNTFSVolume **out_volume,
                 uint32_t *warnings);
void oh_ntfs_close(OHNTFSVolume *volume);
int oh_ntfs_stat(OHNTFSVolume *volume, uint64_t inode, OHNTFSItem *out);
int oh_ntfs_lookup(OHNTFSVolume *volume, uint64_t parent,
                   const char *utf8_name, OHNTFSItem *out);
int oh_ntfs_list(OHNTFSVolume *volume, uint64_t directory,
                 OHNTFSEntryCallback callback, void *context);
/* Case-insensitive match using the volume's $UpCase table, as Windows does. */
int oh_ntfs_name_exists_nocase(OHNTFSVolume *volume, uint64_t directory,
                               const char *utf8_name, int *exists);
/* Resolves a '/'-separated path of existing directories from the root. */
/* Names as NTFS compares them ignoring case: UTF-16 upcased with the
   volume's own table. The listing does not open the entries' inodes, so a
   whole folder is indexed in one pass. */
typedef int (*OHNTFSKeyCallback)(void *context, const uint16_t *key,
                                 const uint16_t *name, int length,
                                 uint64_t inode, int is_directory);
int oh_ntfs_name_key(OHNTFSVolume *volume, const char *utf8_name,
                     uint16_t **key, int *length);
int oh_ntfs_list_keys(OHNTFSVolume *volume, uint64_t directory,
                      OHNTFSKeyCallback callback, void *context);
int oh_ntfs_resolve_directory(OHNTFSVolume *volume, const char *utf8_path,
                              uint64_t *inode);
int oh_ntfs_free_bytes(OHNTFSVolume *volume, uint64_t *out_bytes);
int64_t oh_ntfs_read(OHNTFSVolume *volume, uint64_t inode,
                     uint64_t offset, void *buffer, uint64_t length);
uint64_t oh_ntfs_write_attempts(OHNTFSVolume *volume);
uint64_t oh_ntfs_total_write_attempts(void);

#endif
