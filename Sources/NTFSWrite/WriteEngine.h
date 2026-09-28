#ifndef OPENHDD_WRITE_ENGINE_H
#define OPENHDD_WRITE_ENGINE_H

#include <stddef.h>
#include <stdint.h>

/* Phases reported to the progress callback, in order. */
enum {
    OH_PHASE_PREPARE = 0, /* read-only checks */
    OH_PHASE_WRITE = 1,   /* data written under temporary names */
    OH_PHASE_SYNC = 2,    /* device cache flush */
    OH_PHASE_VERIFY = 3,  /* one full read-back from the drive */
    OH_PHASE_PUBLISH = 4, /* final names added */
    OH_PHASE_FINISH = 5   /* temporaries removed, volume marked clean */
};

/* Reports the whole operation as one unit count: bytes written plus bytes
   verified plus a small fixed cost per file. Must not block. */
typedef void (*OHCopyProgress)(void *context, int phase, size_t file_index,
                               size_t file_count, uint64_t done_units,
                               uint64_t total_units);

typedef struct {
    int source_fd;               /* regular file, opened read-only */
    const char *destination_name; /* UTF-8, NFC, validated by oh_ntfs_valid_new_name */
} OHCopyItem;

/* Stage reported on failure. 1 = preflight (nothing written), 2 = dirty mark
   and writing every file under a temporary name, 3 = verifying the data,
   4 = publishing the final names, 5 = checking names and removing the
   temporaries, 6 = clearing the dirty mark. Any failure at stage >= 2 leaves the volume
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
/* Short description of the last low-level failure, or "" when none. */
const char *oh_last_error(void);
int oh_copy_new_file(int target_fd, uint64_t target_size, int is_device,
                     int source_fd, const char *destination_name,
                     int *failure_stage, uint32_t *safety_warnings);

#endif
