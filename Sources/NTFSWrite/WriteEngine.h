#ifndef OPENHDD_WRITE_ENGINE_H
#define OPENHDD_WRITE_ENGINE_H

#include <stddef.h>
#include <stdint.h>

/* Called after each copied chunk and at file boundaries; must not block. */
typedef void (*OHCopyProgress)(void *context, size_t file_index,
                               uint64_t file_bytes_done, uint64_t file_bytes_total);

typedef struct {
    int source_fd;               /* regular file, opened read-only */
    const char *destination_name; /* UTF-8, NFC, validated by oh_ntfs_valid_new_name */
} OHCopyItem;

/* Stage reported on failure. 1 = preflight (nothing written), 2 = dirty mark or
   data copy, 3 = verify temporary, 4 = publish, 5 = verify/complete,
   6 = clearing the dirty mark. Any failure at stage >= 2 leaves the volume
   marked dirty on purpose: Windows must check it before another write.

   When removed_pending is not NULL and the volume is clean apart from
   temporary names of an earlier interrupted session (Windows has already
   checked it), those temporaries are removed first and counted there. */

/* The caller owns every descriptor and must hold exclusive access to target_fd. */
int oh_ntfs_valid_new_name(const char *name);
int oh_ntfs_valid_directory_path(const char *path);
int oh_ntfs_safety_preflight(int target_fd, uint64_t target_size,
                             uint64_t *free_bytes, uint32_t *warnings);
int oh_copy_new_files(int target_fd, uint64_t target_size, int is_device,
                      const char *directory_path,
                      const OHCopyItem *items, size_t count,
                      OHCopyProgress progress, void *progress_context,
                      size_t *failed_index, int *failure_stage,
                      uint32_t *safety_warnings, size_t *removed_pending);
int oh_copy_new_file(int target_fd, uint64_t target_size, int is_device,
                     int source_fd, const char *destination_name,
                     int *failure_stage, uint32_t *safety_warnings);

#endif
