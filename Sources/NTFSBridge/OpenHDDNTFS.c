#include "OpenHDDNTFS.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#include <ntfs-3g/attrib.h>
#include <ntfs-3g/device.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/logfile.h>
#include <ntfs-3g/logging.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/volume.h>

struct OHNTFSVolume {
    ntfs_volume *ntfs;
    OHNTFSReadBlocks reader;
    void *reader_context;
    uint64_t device_size;
    uint64_t position;
    pthread_mutex_t lock;
    atomic_uint_fast64_t write_attempts;
};

static atomic_uint_fast64_t all_write_attempts;

static struct OHNTFSVolume *context_of(struct ntfs_device *device)
{
    return (struct OHNTFSVolume *)device->d_private;
}

static int device_open(struct ntfs_device *device, int flags)
{
    if ((flags & O_ACCMODE) != O_RDONLY) {
        errno = EROFS;
        return -1;
    }
    NDevSetReadOnly(device);
    NDevSetOpen(device);
    return 0;
}

static int device_close(struct ntfs_device *device)
{
    NDevClearOpen(device);
    return 0;
}

static s64 device_seek(struct ntfs_device *device, s64 offset, int whence)
{
    struct OHNTFSVolume *ctx = context_of(device);
    uint64_t base = 0;
    if (whence == SEEK_CUR) base = ctx->position;
    else if (whence == SEEK_END) base = ctx->device_size;
    else if (whence != SEEK_SET) { errno = EINVAL; return -1; }
    if (base > INT64_MAX ||
        (offset < 0 && (uint64_t)(-(offset + 1)) + 1 > base) ||
        (offset > 0 && (uint64_t)offset > ctx->device_size - base)) {
        errno = EINVAL;
        return -1;
    }
    uint64_t next = offset < 0 ? base - ((uint64_t)(-(offset + 1)) + 1)
                               : base + (uint64_t)offset;
    if (next > ctx->device_size) { errno = EINVAL; return -1; }
    ctx->position = next;
    return (s64)next;
}

static s64 device_pread(struct ntfs_device *device, void *buf, s64 count, s64 offset)
{
    struct OHNTFSVolume *ctx = context_of(device);
    if (count < 0 || offset < 0 || (uint64_t)offset > ctx->device_size ||
        (uint64_t)count > ctx->device_size - (uint64_t)offset) {
        errno = EINVAL;
        return -1;
    }
    if (!count) return 0;
    int64_t n = ctx->reader(ctx->reader_context, (uint64_t)offset,
                            buf, (uint64_t)count);
    if (n < 0) return -1;
    if (n > count) { errno = EIO; return -1; }
    return n;
}

static s64 device_read(struct ntfs_device *device, void *buf, s64 count)
{
    struct OHNTFSVolume *ctx = context_of(device);
    s64 result = device_pread(device, buf, count, (s64)ctx->position);
    if (result > 0) ctx->position += (uint64_t)result;
    return result;
}

static s64 device_write(struct ntfs_device *device, const void *buf, s64 count)
{
    (void)buf; (void)count;
    atomic_fetch_add(&context_of(device)->write_attempts, 1);
    atomic_fetch_add(&all_write_attempts, 1);
    errno = EROFS;
    return -1;
}

static s64 device_pwrite(struct ntfs_device *device, const void *buf,
                         s64 count, s64 offset)
{
    (void)offset;
    return device_write(device, buf, count);
}

static int device_sync(struct ntfs_device *device)
{
    (void)device;
    return 0;
}

static int device_stat(struct ntfs_device *device, struct stat *out)
{
    struct OHNTFSVolume *ctx = context_of(device);
    memset(out, 0, sizeof(*out));
    if (ctx->device_size > INT64_MAX) { errno = EOVERFLOW; return -1; }
    out->st_mode = S_IFREG | 0400;
    out->st_size = (off_t)ctx->device_size;
    out->st_blksize = 512;
    out->st_blocks = (blkcnt_t)(ctx->device_size / 512);
    return 0;
}

static int device_ioctl(struct ntfs_device *device, unsigned long request, void *arg)
{
    (void)device; (void)request; (void)arg;
    errno = ENOTTY;
    return -1;
}

static struct ntfs_device_operations read_only_device = {
    .open = device_open, .close = device_close, .seek = device_seek,
    .read = device_read, .write = device_write, .pread = device_pread,
    .pwrite = device_pwrite, .sync = device_sync,
    .stat = device_stat, .ioctl = device_ioctl
};

static int item_from_inode(ntfs_inode *inode, OHNTFSItem *out)
{
    memset(out, 0, sizeof(*out));
    out->inode = inode->mft_no;
    out->kind = (inode->mrec->flags & MFT_RECORD_IS_DIRECTORY) ? 2 : 1;
    out->hard_link_count = le16_to_cpu(inode->mrec->link_count);
    out->special = (inode->flags & (FILE_ATTR_REPARSE_POINT | FILE_ATTR_ENCRYPTED)) ? 1 : 0;
    if (inode->data_size < 0 || inode->allocated_size < 0) {
        errno = EIO;
        return -1;
    }
    out->size = out->kind == 2 ? 0 : (uint64_t)inode->data_size;
    out->allocated_size = (uint64_t)inode->allocated_size;
    /* NTFS timestamps are 100 ns units since 1601-01-01. */
    const int64_t epoch = 116444736000000000LL;
    if (inode->creation_time > epoch && inode->creation_time - epoch <= INT64_MAX / 100)
        out->created_ns = (inode->creation_time - epoch) * 100;
    if (inode->last_data_change_time > epoch &&
        inode->last_data_change_time - epoch <= INT64_MAX / 100)
        out->modified_ns = (inode->last_data_change_time - epoch) * 100;
    return 0;
}

int oh_ntfs_open(OHNTFSReadBlocks reader, void *context, uint64_t device_size,
                 OHNTFSVolume **out_volume, uint32_t *warnings)
{
    if (!reader || !out_volume || !warnings || device_size < 4096 ||
        device_size > INT64_MAX) return EINVAL;
    *out_volume = NULL;
    *warnings = 0;
    struct OHNTFSVolume *ctx = calloc(1, sizeof(*ctx));
    if (!ctx) return ENOMEM;
    ctx->reader = reader;
    ctx->reader_context = context;
    ctx->device_size = device_size;
    atomic_init(&ctx->write_attempts, 0);
    pthread_mutex_init(&ctx->lock, NULL);
    #ifdef OPENHDD_TESTING
    if (!getenv("OPENHDD_TEST_NTFS_LOG"))
    #endif
    ntfs_log_set_handler(ntfs_log_handler_null);
    struct ntfs_device *device = ntfs_device_alloc("OpenHDD read-only", 0,
                                                   &read_only_device, ctx);
    if (!device) { pthread_mutex_destroy(&ctx->lock); free(ctx); return ENOMEM; }
    ctx->ntfs = ntfs_device_mount(device, NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC);
    if (!ctx->ntfs) {
        int error = errno ? errno : EIO;
        ntfs_device_free(device);
        pthread_mutex_destroy(&ctx->lock);
        free(ctx);
        return error;
    }
    if (ctx->ntfs->flags & VOLUME_IS_DIRTY)
        *warnings |= OH_NTFS_WARNING_DIRTY;
    if (ntfs_volume_check_hiberfile(ctx->ntfs, 0) < 0)
        *warnings |= OH_NTFS_WARNING_HIBERNATED_OR_UNCERTAIN;
    ntfs_inode *log_inode = ntfs_inode_open(ctx->ntfs, FILE_LogFile);
    if (!log_inode) {
        *warnings |= OH_NTFS_WARNING_JOURNAL_SUSPECT;
    } else {
        ntfs_attr *log_data = ntfs_attr_open(log_inode, AT_DATA, AT_UNNAMED, 0);
        if (!log_data) {
            *warnings |= OH_NTFS_WARNING_JOURNAL_SUSPECT;
        } else {
            RESTART_PAGE_HEADER *restart = NULL;
            if (!ntfs_check_logfile(log_data, &restart) ||
                !ntfs_is_logfile_clean(log_data, restart))
                *warnings |= OH_NTFS_WARNING_JOURNAL_SUSPECT;
            free(restart);
            ntfs_attr_close(log_data);
        }
        ntfs_inode_close(log_inode);
    }
    /* RW startup in NTFS-3G rewrites nonresident $TXF_DATA. Refuse such
       volumes before any RW mount; this forensic probe itself never writes. */
    ntfs_inode *root = ntfs_inode_open(ctx->ntfs, FILE_root);
    if (!root) {
        *warnings |= OH_NTFS_WARNING_TXF_REWRITE_RISK;
    } else {
        errno = 0;
        ntfs_attr *txf = ntfs_attr_open(root, AT_LOGGED_UTILITY_STREAM,
                                        TXF_DATA, 9);
        if (txf) {
            if (NAttrNonResident(txf))
                *warnings |= OH_NTFS_WARNING_TXF_REWRITE_RISK;
            ntfs_attr_close(txf);
        } else if (errno != ENOENT) {
            *warnings |= OH_NTFS_WARNING_TXF_REWRITE_RISK;
        }
        if (ntfs_inode_close(root))
            *warnings |= OH_NTFS_WARNING_TXF_REWRITE_RISK;
    }
    *out_volume = ctx;
    return 0;
}

void oh_ntfs_close(OHNTFSVolume *ctx)
{
    if (!ctx) return;
    pthread_mutex_lock(&ctx->lock);
    ntfs_umount(ctx->ntfs, FALSE);
    pthread_mutex_unlock(&ctx->lock);
    pthread_mutex_destroy(&ctx->lock);
    free(ctx);
}

int oh_ntfs_stat(OHNTFSVolume *ctx, uint64_t inode, OHNTFSItem *out)
{
    if (!ctx || !out || inode > 0x0000ffffffffffffULL) return EINVAL;
    pthread_mutex_lock(&ctx->lock);
    ntfs_inode *ni = ntfs_inode_open(ctx->ntfs, inode);
    if (!ni) { int e = errno ? errno : EIO; pthread_mutex_unlock(&ctx->lock); return e; }
    int result = item_from_inode(ni, out) ? (errno ? errno : EIO) : 0;
    if (ntfs_inode_close(ni) && !result) result = EIO;
    pthread_mutex_unlock(&ctx->lock);
    return result;
}

int oh_ntfs_lookup(OHNTFSVolume *ctx, uint64_t parent,
                   const char *name, OHNTFSItem *out)
{
    if (!ctx || !name || !out || !*name || strchr(name, '/') ||
        parent > 0x0000ffffffffffffULL) return EINVAL;
    pthread_mutex_lock(&ctx->lock);
    ntfs_inode *dir = ntfs_inode_open(ctx->ntfs, parent);
    if (!dir) { int e = errno ? errno : EIO; pthread_mutex_unlock(&ctx->lock); return e; }
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    int result = 0;
    if (length < 0 || length > 255) result = EINVAL;
    u64 mref = result ? 0 : ntfs_inode_lookup_by_name(dir, wide, length);
    free(wide);
    if (!result && IS_ERR_MREF(mref)) result = errno ? errno : ENOENT;
    ntfs_inode *ni = result ? NULL : ntfs_inode_open(ctx->ntfs, mref);
    if (!result && !ni) result = errno ? errno : EIO;
    if (ni) {
        if (item_from_inode(ni, out)) result = errno ? errno : EIO;
        if (ntfs_inode_close(ni) && !result) result = EIO;
    }
    if (ntfs_inode_close(dir) && !result) result = EIO;
    pthread_mutex_unlock(&ctx->lock);
    return result;
}

struct listing {
    OHNTFSVolume *volume;
    OHNTFSEntryCallback callback;
    void *context;
    int error;
    uint32_t count;
};

static int fill_entry(void *opaque, const ntfschar *name, int name_length,
                      int name_type, s64 position, MFT_REF mref, unsigned type)
{
    (void)position; (void)type;
    struct listing *listing = opaque;
    if (name_type == FILE_NAME_DOS) return 0;
    if (++listing->count > 100000) { listing->error = EOVERFLOW; return 1; }
    char *utf8 = NULL;
    int converted = ntfs_ucstombs(name, name_length, &utf8, 0);
    if (converted < 0) {
        listing->error = EILSEQ; return 1;
    }
    if (!utf8 || !converted || strlen(utf8) != (size_t)converted ||
        strchr(utf8, '/')) {
        listing->error = EILSEQ;
        free(utf8); return 1;
    }
    if (!strcmp(utf8, ".") || !strcmp(utf8, "..")) {
        free(utf8); return 0;
    }
    ntfs_inode *ni = ntfs_inode_open(listing->volume->ntfs, mref);
    if (!ni) { listing->error = errno ? errno : EIO; free(utf8); return 1; }
    OHNTFSItem item;
    int stat_error = item_from_inode(ni, &item);
    int stat_errno = errno;
    ntfs_inode_close(ni);
    if (stat_error) { listing->error = stat_errno ? stat_errno : EIO; free(utf8); return 1; }
    int cb = listing->callback(listing->context, utf8, &item);
    free(utf8);
    if (cb) { listing->error = cb > 0 ? cb : EIO; return 1; }
    return 0;
}

int oh_ntfs_list(OHNTFSVolume *ctx, uint64_t directory,
                 OHNTFSEntryCallback callback, void *context)
{
    if (!ctx || !callback || directory > 0x0000ffffffffffffULL) return EINVAL;
    pthread_mutex_lock(&ctx->lock);
    ntfs_inode *dir = ntfs_inode_open(ctx->ntfs, directory);
    if (!dir) { int e = errno ? errno : EIO; pthread_mutex_unlock(&ctx->lock); return e; }
    if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) {
        ntfs_inode_close(dir); pthread_mutex_unlock(&ctx->lock); return ENOTDIR;
    }
    struct listing listing = { .volume = ctx, .callback = callback, .context = context };
    s64 position = 0;
    int result = ntfs_readdir(dir, &position, &listing, fill_entry);
    int error = listing.error ? listing.error : result ? (errno ? errno : EIO) : 0;
    if (ntfs_inode_close(dir) && !error) error = EIO;
    pthread_mutex_unlock(&ctx->lock);
    return error;
}

struct name_probe {
    ntfs_volume *ntfs;
    const ntfschar *name;
    int length;
    int found;
};

static int probe_entry(void *opaque, const ntfschar *name, int name_length,
                       int name_type, s64 position, MFT_REF mref, unsigned type)
{
    (void)name_type; (void)position; (void)mref; (void)type;
    struct name_probe *probe = opaque;
    if (ntfs_names_are_equal(name, (size_t)name_length, probe->name,
                             (size_t)probe->length, IGNORE_CASE,
                             probe->ntfs->upcase, probe->ntfs->upcase_len)) {
        probe->found = 1;
        return 1;
    }
    return 0;
}

int oh_ntfs_name_exists_nocase(OHNTFSVolume *ctx, uint64_t directory,
                               const char *name, int *exists)
{
    if (!ctx || !name || !*name || !exists || strchr(name, '/') ||
        directory > 0x0000ffffffffffffULL) return EINVAL;
    *exists = 0;
    ntfschar *wide = NULL;
    int length = ntfs_mbstoucs(name, &wide);
    if (length <= 0 || length > 255) { free(wide); return EINVAL; }
    pthread_mutex_lock(&ctx->lock);
    ntfs_inode *dir = ntfs_inode_open(ctx->ntfs, directory);
    int error = 0;
    if (!dir) error = errno ? errno : EIO;
    else if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) error = ENOTDIR;
    if (!error) {
        struct name_probe probe = { .ntfs = ctx->ntfs, .name = wide, .length = length };
        s64 position = 0;
        errno = 0;
        int result = ntfs_readdir(dir, &position, &probe, probe_entry);
        if (probe.found) *exists = 1;
        else if (result) error = errno ? errno : EIO;
    }
    if (dir && ntfs_inode_close(dir) && !error) error = EIO;
    pthread_mutex_unlock(&ctx->lock);
    free(wide);
    return error;
}

int oh_ntfs_name_key(OHNTFSVolume *ctx, const char *name, uint16_t **key,
                     int *length)
{
    if (!ctx || !name || !key || !length) return EINVAL;
    ntfschar *wide = NULL;
    int count = ntfs_mbstoucs(name, &wide);
    if (count <= 0 || count > 255) { free(wide); return EINVAL; }
    ntfs_name_upcase(wide, (u32)count, ctx->ntfs->upcase, ctx->ntfs->upcase_len);
    *key = (uint16_t *)wide;
    *length = count;
    return 0;
}

struct key_listing {
    ntfs_volume *ntfs;
    OHNTFSKeyCallback callback;
    void *context;
    int error;
    uint32_t count;
};

static int key_entry(void *opaque, const ntfschar *name, int name_length,
                     int name_type, s64 position, MFT_REF mref, unsigned type)
{
    (void)position;
    struct key_listing *listing = opaque;
    if (name_type == FILE_NAME_DOS || name_length <= 0 || name_length > 255) return 0;
    if ((name_length == 1 && le16_to_cpu(name[0]) == '.') ||
        (name_length == 2 && le16_to_cpu(name[0]) == '.' && le16_to_cpu(name[1]) == '.'))
        return 0;
    if (++listing->count > 1000000) { listing->error = EOVERFLOW; return 1; }
    ntfschar original[255], key[255];
    memcpy(original, name, (size_t)name_length * sizeof(ntfschar));
    memcpy(key, name, (size_t)name_length * sizeof(ntfschar));
    ntfs_name_upcase(key, (u32)name_length, listing->ntfs->upcase, listing->ntfs->upcase_len);
    int cb = listing->callback(listing->context, (const uint16_t *)key,
                               (const uint16_t *)original, name_length,
                               MREF(mref), type == NTFS_DT_DIR);
    if (cb) { listing->error = cb > 0 ? cb : EIO; return 1; }
    return 0;
}

int oh_ntfs_list_keys(OHNTFSVolume *ctx, uint64_t directory,
                      OHNTFSKeyCallback callback, void *context)
{
    if (!ctx || !callback || directory > 0x0000ffffffffffffULL) return EINVAL;
    pthread_mutex_lock(&ctx->lock);
    ntfs_inode *dir = ntfs_inode_open(ctx->ntfs, directory);
    int error = 0;
    if (!dir) error = errno ? errno : EIO;
    else if (!(dir->mrec->flags & MFT_RECORD_IS_DIRECTORY)) error = ENOTDIR;
    if (!error) {
        struct key_listing listing = { .ntfs = ctx->ntfs, .callback = callback,
                                       .context = context };
        s64 position = 0;
        errno = 0;
        int result = ntfs_readdir(dir, &position, &listing, key_entry);
        if (listing.error) error = listing.error;
        else if (result) error = errno ? errno : EIO;
    }
    if (dir && ntfs_inode_close(dir) && !error) error = EIO;
    pthread_mutex_unlock(&ctx->lock);
    return error;
}

int oh_ntfs_resolve_directory(OHNTFSVolume *ctx, const char *path,
                              uint64_t *inode)
{
    if (!ctx || !path || !inode || strlen(path) > 4096) return EINVAL;
    uint64_t current = FILE_root;
    char *copy = strdup(path);
    if (!copy) return ENOMEM;
    int error = 0;
    char *cursor = copy, *component;
    while (!error && (component = strsep(&cursor, "/"))) {
        if (!*component) continue;
        if (!strcmp(component, ".") || !strcmp(component, "..")) { error = EINVAL; break; }
        OHNTFSItem item;
        error = oh_ntfs_lookup(ctx, current, component, &item);
        if (!error && item.kind != 2) error = ENOTDIR;
        if (!error) current = item.inode;
    }
    free(copy);
    if (!error) *inode = current;
    return error;
}

int oh_ntfs_free_bytes(OHNTFSVolume *ctx, uint64_t *out_bytes)
{
    if (!ctx || !out_bytes) return EINVAL;
    pthread_mutex_lock(&ctx->lock);
    int status = ntfs_volume_get_free_space(ctx->ntfs);
    s64 clusters = ctx->ntfs->free_clusters;
    u32 size = ctx->ntfs->cluster_size;
    int error = status || clusters < 0 || !size ||
        (uint64_t)clusters > UINT64_MAX / size ? EIO : 0;
    if (!error) *out_bytes = (uint64_t)clusters * size;
    pthread_mutex_unlock(&ctx->lock);
    return error;
}

int64_t oh_ntfs_read(OHNTFSVolume *ctx, uint64_t inode,
                     uint64_t offset, void *buffer, uint64_t length)
{
    if (!ctx || (!buffer && length) || inode > 0x0000ffffffffffffULL ||
        offset > INT64_MAX || length > INT64_MAX || length > INT64_MAX - offset) {
        errno = EINVAL; return -1;
    }
    if (!length) return 0;
    pthread_mutex_lock(&ctx->lock);
    ntfs_inode *ni = ntfs_inode_open(ctx->ntfs, inode);
    if (!ni) { pthread_mutex_unlock(&ctx->lock); return -1; }
    if (ni->mrec->flags & MFT_RECORD_IS_DIRECTORY) {
        ntfs_inode_close(ni); pthread_mutex_unlock(&ctx->lock); errno = EISDIR; return -1;
    }
    if (ni->flags & (FILE_ATTR_ENCRYPTED | FILE_ATTR_REPARSE_POINT)) {
        ntfs_inode_close(ni); pthread_mutex_unlock(&ctx->lock); errno = ENOTSUP; return -1;
    }
    ntfs_attr *attr = ntfs_attr_open(ni, AT_DATA, AT_UNNAMED, 0);
    if (!attr) { int e = errno; ntfs_inode_close(ni); pthread_mutex_unlock(&ctx->lock); errno = e; return -1; }
    s64 n = ntfs_attr_pread(attr, (s64)offset, (s64)length, buffer);
    int e = errno;
    ntfs_attr_close(attr);
    if (ntfs_inode_close(ni) && n >= 0) { n = -1; e = EIO; }
    pthread_mutex_unlock(&ctx->lock);
    errno = e;
    return n;
}

uint64_t oh_ntfs_write_attempts(OHNTFSVolume *ctx)
{
    return ctx ? atomic_load(&ctx->write_attempts) : 0;
}

uint64_t oh_ntfs_total_write_attempts(void)
{
    return atomic_load(&all_write_attempts);
}
