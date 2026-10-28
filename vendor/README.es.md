# Procedencia del código fuente de NTFS-3G

[English](README.md) · [Italiano](README.it.md) · **Español**

- Proyecto original: Tuxera, NTFS-3G / ntfsprogs 2026.7.7
- Archivo de fuentes: https://tuxera.com/opensource/ntfs-3g_ntfsprogs-2026.7.7.tgz
- SHA-256 del archivo original: `d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab`
- Versión: https://github.com/tuxera/ntfs-3g/releases/tag/2026.7.7
- Licencia: GPL-2.0-or-later para libntfs-3g (véase `ntfs-3g-2026.7.7/COPYING`); algunos componentes usan LGPL-2.0-or-later (véase `COPYING.LIB`).

El código fuente original se incluye sin modificaciones locales. La compilación
usa una carpeta separada. Custodrive enlaza libntfs-3g en su
motor de copia y se distribuye en conjunto bajo GPL-2.0-or-later (ver
`LICENSE` en la raíz del repositorio); cada versión indica la revisión del
código fuente con la que se compiló.

El adaptador C llama a `ntfs_device_mount` con `NTFS_MNT_RDONLY | NTFS_MNT_FORENSIC`.
Sus callbacks de escritura y pwrite devuelven siempre `EROFS` y cuentan los
intentos. Es una defensa adicional, no una prueba de seguridad de toda la
aplicación hasta superar las pruebas completas con imágenes y dispositivos.
