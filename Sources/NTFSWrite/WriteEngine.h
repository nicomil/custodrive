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
    const char *directory;       /* folder relative to the root; NULL or "" = root */
    int replace;                 /* 1: an existing file with exactly this name is
                                    replaced once the new one is verified */
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
/* Copies files into any folders of the volume, first creating the folders
   listed in `directories` (relative paths, parents before children; ones
   that already exist are kept and merged). An item with replace = 1 swaps
   an existing file of the same name only after the new data is verified;
   the swap is recorded in a recovery journal. Recovery validates identities
   and contents before choosing an action; ambiguous states are preserved
   and refused. This does not guarantee recovery from torn metadata. `count` may be 0
   when only folders are created. */
int oh_copy_files(int target_fd, uint64_t target_size, int is_device,
                  const char *const *directories, size_t directory_count,
                  const OHCopyItem *items, size_t count,
                  OHCopyProgress progress, void *progress_context,
                  size_t *failed_index, int *failure_stage,
                  uint32_t *safety_warnings, size_t *removed_pending);
/* Progress units oh_copy_files reports as its total, so that a caller
   running several batches can show one bar. */
uint64_t oh_copy_work_units(uint64_t bytes, size_t files, size_t directories);
int oh_copy_new_files(int target_fd, uint64_t target_size, int is_device,
                      const char *directory_path,
                      const OHCopyItem *items, size_t count,
                      OHCopyProgress progress, void *progress_context,
                      size_t *failed_index, int *failure_stage,
                      uint32_t *safety_warnings, size_t *removed_pending);
/* v2 edits of existing entries. Paths are relative to the volume root,
   '/'-separated, NFC. Delete removes a file or a whole folder (never
   following junctions or symbolic links); rename stays in the same folder;
   new folder creates `name` inside `path` ("" for the root); move puts
   `path` into the folder `name` ("" for the root), keeping its name. All
   edits of a call run in one session marked dirty, like a copy. */
enum { OH_EDIT_DELETE = 1, OH_EDIT_RENAME = 2, OH_EDIT_MKDIR = 3, OH_EDIT_MOVE = 4 };
typedef struct {
    int kind;
    const char *path;
    const char *name; /* new name (rename, new folder) or destination folder (move) */
} OHEdit;
int oh_edit_volume(int target_fd, uint64_t target_size, int is_device,
                   const OHEdit *edits, size_t count,
                   OHCopyProgress progress, void *progress_context,
                   size_t *failed_index, int *failure_stage,
                   uint32_t *safety_warnings, size_t *removed_pending);

/* Asks a running copy to stop; safe to call from a signal handler. While
   files are being written or verified the batch is undone (temporaries and
   the folders it created are removed, the volume is left clean) and the
   copy returns ECANCELED; once publishing has started it completes. */
void oh_request_cancel(void);
int oh_cancel_requested(void);

/* Read-only browsing for an edit session: list folders and export files
   through the same exclusive descriptor the session writes with. A view
   must be closed before any write and reopened afterwards. */
typedef struct OHView OHView;
typedef struct {
    int kind;             /* 1 = file, 2 = folder */
    int special;          /* junction, symbolic link or encrypted */
    uint64_t size;
    int64_t modified_ns;  /* since 1970 */
} OHEntryInfo;
typedef int (*OHViewEntry)(void *context, const char *name, const OHEntryInfo *info);
int oh_view_open(int target_fd, uint64_t target_size, int is_device,
                 OHView **view, uint32_t *safety_warnings);
/* Lists `path` ("" for the root); names come back NFC. NTFS system files,
   System Volume Information and OpenHDD's own entries are not listed. */
int oh_view_list(OHView *view, const char *path, OHViewEntry callback, void *context);
/* Copies the file at `path` into out_fd (already open for writing). */
int oh_view_export(OHView *view, const char *path, int out_fd, uint64_t *copied);
void oh_view_close(OHView *view);
/* Clears a stop request once the operation it was meant for has ended. */
void oh_reset_cancel(void);

/* Short description of the last low-level failure, or "" when none. */
const char *oh_last_error(void);
int oh_copy_new_file(int target_fd, uint64_t target_size, int is_device,
                     int source_fd, const char *destination_name,
                     int *failure_stage, uint32_t *safety_warnings);

#endif
