#!/bin/sh
# Builds Custodrive and packs it into a disk image to share with other Macs
# (Apple Silicon, macOS 15.4 or later): Build/Custodrive-VERSION.dmg.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
Scripts/build-local-app.sh
app="$project_dir/Build/Custodrive.app"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
stage=$(mktemp -d "${TMPDIR:-/tmp}/custodrive-dmg.XXXXXX")
trap 'rm -rf "$stage"' EXIT HUP INT TERM

ditto "$app" "$stage/Custodrive.app"
ln -s /Applications "$stage/Applicazioni"
cat > "$stage/Leggimi - Installazione.txt" <<TEXT
Custodrive $version — dischi esterni al sicuro
Requisiti: Mac con chip Apple (M1 o successivi), macOS 15.4 o successivo.

INSTALLAZIONE
1. Trascina «Custodrive» sulla cartella «Applicazioni».
2. Apri Custodrive dalla cartella Applicazioni.

PRIMA APERTURA SU UN ALTRO MAC
Custodrive non è firmato con un certificato Apple Developer, quindi macOS
la blocca la prima volta («non è possibile verificare lo sviluppatore»).
Per aprirla:
  a. Prova ad aprirla una volta e chiudi l'avviso.
  b. Impostazioni di Sistema → Privacy e sicurezza → in fondo, accanto a
     «Custodrive è stata bloccata», premi «Apri comunque» e conferma con la
     password.
Oppure, dal Terminale:
  xattr -dr com.apple.quarantine /Applications/Custodrive.app
Serve solo la prima volta.

USO
Collega un disco NTFS, selezionalo a sinistra. Trascina file dal Finder
nella finestra per copiarli; la prima modifica chiede la password una sola
volta. Premi «Termina modifiche» o «Espelli» prima di scollegare il disco.
TEXT

dmg="$project_dir/Build/Custodrive-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Custodrive $version" -srcfolder "$stage" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 "$dmg"
hdiutil verify -quiet "$dmg"
shasum -a 256 "$dmg" | awk '{print $1}' > "$dmg.sha256"
printf 'Package: %s (%s)\n' "$dmg" "$(du -h "$dmg" | awk '{print $1}')"
