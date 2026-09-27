#ifndef OPENHDD_WRITE_ENGINE_H
#define OPENHDD_WRITE_ENGINE_H

#include <stdint.h>

/* The caller owns both descriptors and must hold exclusive access to target_fd. */
int oh_ntfs_valid_new_name(const char *name);
int oh_ntfs_safety_preflight(int target_fd, uint64_t target_size,
                             uint64_t *free_bytes, uint32_t *warnings);
int oh_copy_new_file(int target_fd, uint64_t target_size, int is_device,
                     int source_fd, const char *destination_name,
                     int *failure_stage, uint32_t *safety_warnings);

#endif
