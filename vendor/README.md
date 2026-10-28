# NTFS-3G source provenance

**English** · [Italiano](README.it.md) · [Español](README.es.md)

- Upstream: Tuxera, NTFS-3G / ntfsprogs 2026.7.7
- Source archive: https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.7.7.tgz
- SHA-256 of original archive: `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`
- Release: https://github.com/tuxera/ntfs-3g/releases/tag/2026.7.7
- License: GPL-2.0-or-later for libntfs-3g (see `ntfs-3g-2026.7.7/COPYING`); some components use LGPL-2.0-or-later (see `COPYING.LIB`).

The original source is vendored without local modifications. Builds use a separate build directory. The app is for personal use; any distribution requires a separate license review and fulfillment of GPL obligations.

The C adapter calls `ntfs_device_mount` with `NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC`. Its device write and pwrite callbacks always return `EROFS` and count attempted calls. This is a defense in depth measure, not proof that the complete app is safe until end-to-end image and device tests pass.
