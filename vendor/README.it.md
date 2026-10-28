# Provenienza dei sorgenti NTFS-3G

[English](README.md) · **Italiano** · [Español](README.es.md)

- Progetto originale: Tuxera, NTFS-3G / ntfsprogs 2026.7.7
- Archivio sorgente: https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.7.7.tgz
- SHA-256 dell’archivio originale: `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`
- Release: https://github.com/tuxera/ntfs-3g/releases/tag/2026.7.7
- Licenza: GPL-2.0-or-later per libntfs-3g (vedi `ntfs-3g-2026.7.7/COPYING`); alcuni componenti usano LGPL-2.0-or-later (vedi `COPYING.LIB`).

I sorgenti originali sono inclusi senza modifiche locali. La compilazione usa
una cartella separata. L’app è per uso personale; qualsiasi distribuzione
richiede una verifica separata delle licenze e l’adempimento degli obblighi GPL.

L’adattatore C chiama `ntfs_device_mount` con `NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC`.
Le callback di scrittura e pwrite del dispositivo restituiscono sempre `EROFS`
e contano i tentativi. È una difesa aggiuntiva, non una prova che l’intera app
sia sicura finché non passano i test completi su immagini e dispositivi.
