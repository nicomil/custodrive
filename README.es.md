<p align="center">
  <img src="docs/images/icon.png" width="128" alt="Icono de Custodrive">
</p>

<h1 align="center">Custodrive</h1>

<p align="center">
  <b>Copias verificadas en tus discos externos.</b><br>
  Lee y escribe en discos y unidades USB de Windows (NTFS) desde el Mac,
  con cada operación verificada.
</p>

<p align="center">
  Mac con Apple Silicon · macOS 15.4 o posterior · gratis, sin controladores ni suscripciones
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.it.md">Italiano</a> · <b>Español</b>
</p>

---

macOS lee discos NTFS, pero no puede escribir en ellos. Custodrive permite
copiar fotos y vídeos, crear carpetas, renombrar, mover y eliminar elementos
en discos formateados por Windows, con una interfaz similar al Finder. Las
copias se releen y verifican. Una interrupción puede dañar el sistema de
archivos: la marca «necesita comprobación» y el diario ayudan a recuperarlo,
pero no garantizan que no haya pérdidas. Conserva una copia de los datos importantes.

La interfaz admite **inglés (predeterminado), italiano y español**. Usa el
menú **Idioma** (icono del globo) de la barra de herramientas o **Custodrive →
Ajustes…**, y reinicia la aplicación para aplicar tu elección. Las sesiones
de edición y las copias en curso continúan normalmente. Las capturas muestran
la interfaz en italiano.

<p align="center">
  <img src="docs/images/01-browser.png" width="780" alt="Custodrive: discos a la izquierda, contenido a la derecha">
</p>

## Índice

- [Primeros pasos](#primeros-pasos)
- [Funciones](#funciones)
- [Cómo protege tus datos](#cómo-protege-tus-datos)
- [Atajos de teclado](#atajos-de-teclado)
- [Problemas frecuentes](#problemas-frecuentes)
- [Requisitos y límites](#requisitos-y-límites)
- [Funciones previstas](#funciones-previstas)
- [Para desarrolladores](#para-desarrolladores)

## Primeros pasos

### 1. Instalar

1. Abre `Custodrive-1.1.0.dmg` y arrastra **Custodrive** a **Aplicaciones**.
2. Abre Custodrive desde Aplicaciones.

**La primera vez en un Mac nuevo**, macOS la bloquea porque «no se puede
verificar el desarrollador»: Custodrive no se distribuye con un certificado
Apple Developer. Cierra el aviso, ve a **Ajustes del Sistema → Privacidad y
seguridad** y pulsa **Abrir igualmente** junto a «Custodrive», al final de
la página. También puedes usar Terminal:

```sh
xattr -dr com.apple.quarantine /Applications/Custodrive.app
```

Solo hace falta una vez por Mac.

### 2. Conectar un disco y explorarlo

Conecta un disco o una unidad USB NTFS: aparece a la izquierda, bajo
**Discos externos**. Selecciónalo y explora sus carpetas como en el Finder.
Mientras no modifiques nada, el disco permanece montado en modo de solo
lectura y también está visible en el Finder.

<p align="center">
  <img src="docs/images/02-folder.png" width="780" alt="Una carpeta de fotos abierta en Custodrive">
</p>

### 3. Copiar y editar

Arrastra archivos o carpetas desde el Finder a la ventana o sobre una
carpeta. Al realizar el primer cambio, macOS pide la **contraseña de
administrador una sola vez**. El disco pasa a **Edición activa**: queda
reservado para Custodrive y cada operación se aplica inmediatamente.

<p align="center">
  <img src="docs/images/03-edit-session.png" width="780" alt="Edición activa: disco reservado para Custodrive">
</p>

### 4. Terminar y expulsar

Cuando acabes, pulsa **Terminar edición**: el disco vuelve al modo de solo
lectura y aparece en el Finder. Usa **Expulsar** antes de desconectarlo.
Expulsar el disco o cerrar la aplicación también termina la edición.

## Funciones

### Explorar

- **Barra lateral** con los discos externos y su estado (solo lectura,
  edición activa, comprobación necesaria).
- **Lista de columnas** (nombre, tamaño, fecha), ordenable con un clic en
  la cabecera; las carpetas siempre aparecen primero.
- **Ruta navegable**, botones Atrás, Adelante y Carpeta superior.
- **Doble clic** para abrir carpetas o archivos.
- **Quick Look** con la barra espaciadora, como en el Finder.
- Durante la **edición activa**, abrir un archivo pide dónde guardar una
  copia en el Mac. Los cambios del editor permanecen allí: para devolverlos
  al disco NTFS, cópialos con Custodrive. Las vistas previas de Quick Look
  son temporales y de solo lectura.

### Copiar desde el Mac

- Arrastra archivos y **carpetas completas** desde el Finder: se recrean
  todas las subcarpetas. Se omiten los archivos de servicio del Mac
  (`.DS_Store`, `._*`); no se siguen los enlaces simbólicos.
- También puedes usar **Copiar archivos aquí desde el Mac…**, hacer clic
  derecho en archivos del Finder → **Servicios → Copiar en disco NTFS con
  Custodrive**, o arrastrarlos al **icono de Custodrive en el Dock**. Los
  archivos llegan a la carpeta abierta en la aplicación. El nombre del
  servicio del Finder sigue el idioma del sistema.
- Cada archivo se **relee del disco y se compara** (SHA-256) con el original
  antes de aparecer con su nombre definitivo.
- **Archivos existentes**: Custodrive pregunta si quieres **Sustituir** u
  **Omitir estos**. El archivo anterior se conserva hasta verificar el nuevo.
- Las **copias grandes** avanzan por lotes (1000 archivos u 8 GB cada vez),
  con una sola barra, velocidad y tiempo restante.

<p align="center">
  <img src="docs/images/04-copy-progress.png" width="780" alt="Copia en curso, tiempo restante y botón Cancelar">
</p>

### Organizar

- **Nueva carpeta** (⇧⌘N): se crea con el nombre listo para editar.
- **Renombrar**: selecciona, pulsa Intro y escribe directamente en la
  lista. También puedes cambiar solo las mayúsculas y minúsculas.
- **Mover**: arrastra elementos sobre una carpeta o usa ⌘X y después ⌘V
  en el destino. Es inmediato; los datos no se vuelven a copiar.
- **Eliminar** (⌘⌫): archivos y carpetas con todo su contenido. NTFS no
  tiene Papelera, así que Custodrive siempre pide confirmación.
- **Menú contextual** con todas las acciones mediante clic derecho.

<p align="center">
  <img src="docs/images/05-delete-confirm.png" width="260" alt="Confirmación de eliminación">
</p>

### Cola y cancelación

- Los elementos arrastrados mientras hay una copia en curso se ponen **en
  cola**, bajo la misma barra.
- **Cancelar** solicita detener la copia:
  - si la reversión funciona, se elimina el lote actual y el disco queda limpio;
  - los lotes completados permanecen en el disco, verificados;
  - se vacía la cola.

## Cómo protege tus datos

Custodrive aplica estas medidas para detectar errores y limitar daños:

1. **Marca el disco como «necesita comprobación»** (bit dirty de NTFS)
   antes de cada cambio. Solo retira la marca cuando la operación ha
   terminado y se ha verificado. Tras una interrupción, la marca requiere
   una comprobación en Windows; el resultado de `chkdsk` depende de los daños.
2. **No sobrescribe nada en el mismo lugar.** Los archivos nuevos se
   escriben aparte y se releen; solo después reciben sus nombres definitivos.
   Al sustituir, conserva el archivo anterior hasta colocar el nuevo.
3. **Un diario de recuperación** registra sustituciones, movimientos y
   renombrados. Tras comprobar el sistema de archivos, Custodrive verifica
   el diario antes de completar o deshacer la operación. Si los nombres,
   identidades o contenidos son ambiguos, rechaza la recuperación y
   conserva lo que encuentra.
4. **Rechaza discos de riesgo.** No escribe en discos con Windows hibernado
   o Inicio rápido, con el diario sin cerrar o ya marcados para comprobar,
   y explica el motivo.
5. **Protege archivos del sistema.** Nunca modifica ni sigue `$MFT`,
   `System Volume Information`, junctions, enlaces simbólicos ni archivos cifrados.

Las pruebas automáticas incluyen errores de E/S e interrupciones simuladas.
Los casos ilegibles o que necesitan reparación permanecen **inconclusos**
hasta verificarlos en Windows. Las pruebas históricas de Windows y USB
corresponden a versiones anteriores: no certifican automáticamente el motor
actual. Estado y límites: [notas de desarrollo (italiano)](docs/sviluppo.md).

## Atajos de teclado

| Acción | Teclas |
|---|---|
| Abrir carpeta o archivo | doble clic, ⌘↓ |
| Carpeta superior | ⌘↑ |
| Atrás / Adelante | ⌘[ / ⌘] |
| Quick Look | Espacio |
| Renombrar | Intro |
| Nueva carpeta | ⇧⌘N |
| Copiar archivos aquí desde el Mac | ⇧⌘O |
| Cortar (para mover) / Pegar | ⌘X / ⌘V |
| Eliminar | ⌘⌫ |

## Problemas frecuentes

**«Windows no cerró el disco correctamente (diario NTFS abierto)».**
Se desconectó el disco de Windows sin extracción segura. Reconéctalo a
Windows, usa **Quitar hardware de forma segura** y vuelve a probar en el Mac.

**«Windows está hibernando o tiene Inicio rápido activado».** Apaga Windows
por completo (no solo suspensión) o desactiva Inicio rápido.

**«Hay que comprobar el disco en Windows».** Se interrumpió una operación.
Primero guarda una copia de los datos que aún sean accesibles. En una copia
prescindible, o después de guardar los datos, abre el Símbolo del sistema de
Windows como administrador y ejecuta `chkdsk X: /f`, donde X es la letra de
la unidad. `chkdsk` modifica el sistema de archivos y no garantiza la
recuperación. **Si Windows propone formatear el disco, recházalo.** Custodrive
solo puede continuar cuando el volumen supera las comprobaciones; un diario
ambiguo requiere revisión manual. No elimines archivos `.OpenHDD-*` para
forzar la continuación.

**«Recuperación suspendida — escrituras bloqueadas».** La aplicación muestra
el motivo, la entrada del diario y las rutas esperadas; no afirma haber
encontrado archivos movidos por Windows. Puedes explorar también los
archivos temporales, **Guardar archivo seleccionado** en otro disco o
**Abrir en el Finder** en modo de solo lectura para copiar carpetas.
**Guardar informe** conserva el diagnóstico, incluidos nombres privados.
**Volver a comprobar** valida el volumen sin escribir: la edición vuelve a
estar disponible solo si se superan todas las comprobaciones. Si persiste
la ambigüedad, conserva el original y el diario y solicita asistencia;
no existe un desbloqueo forzado.

**No veo el disco en el Finder.** Durante la edición activa, el disco queda
reservado para Custodrive: pulsa **Terminar edición**.

## Requisitos y límites

- Mac con chip Apple (M1 o posterior), macOS 15.4 o posterior.
- Discos y unidades USB **NTFS** externos. Para APFS, exFAT y FAT, usa el Finder.
- La escritura se realiza dentro de Custodrive; el Finder ve el disco en
  modo de solo lectura.
- No se editan archivos «en el mismo lugar» (por ejemplo, abrir un documento
  en el disco y guardarlo allí): se copian, sustituyen o mueven.
- No se escriben archivos NTFS comprimidos o cifrados.

## Funciones previstas

Custodrive quiere cuidar tus discos más allá de servir como puente a NTFS.
Próximas funciones previstas:

- **Clonación** de discos y unidades USB, para tener una copia preparada
  si falla una unidad.
- **Sincronización** entre un disco y una carpeta del Mac (u otro disco),
  con verificación del contenido.
- **Comprobación de salud** de las unidades, para detectar fallos a tiempo.

## Para desarrolladores

```sh
Scripts/build-local-app.sh    # compila Build/Custodrive.app
Scripts/package-app.sh        # crea Build/Custodrive-1.1.0.dmg para compartir
sh Tests/run-localization-test.sh  # verifica los tres catálogos de idiomas
```

Compilación, motor de línea de comandos, pruebas automáticas, validación en
Windows e historia: [notas de desarrollo (italiano)](docs/sviluppo.md).
El motor NTFS se basa en [NTFS-3G](vendor/README.es.md).

Textos de la interfaz en `Resources/Localization/{en,it,es}.lproj`.
El inglés es el idioma predeterminado y de respaldo. `CustodriveLanguage`
guarda la elección; un reinicio la aplica a SwiftUI y a los diálogos de
AppKit. Los diagnósticos técnicos, rutas y nombres de archivos conservan
sus valores originales.

## Licencia

Custodrive es software libre, distribuido bajo la
[GNU General Public License, versión 2 o (a tu elección) cualquier versión posterior](LICENSE)
(GPL-2.0-or-later). Su motor de copia usa [NTFS-3G](vendor/README.es.md) de
Tuxera, con la misma licencia; el código fuente original de NTFS-3G está en
`vendor/`. Custodrive se ofrece sin ninguna garantía: guarda una copia de
los datos importantes.
