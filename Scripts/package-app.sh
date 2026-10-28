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
ln -s /Applications "$stage/Applications"
cp Resources/Documentation/Install.*.txt "$stage/"
cp LICENSE "$stage/License.txt"

# GPL: every package says exactly which source revision it was built from.
revision=$(git rev-parse HEAD)
if [ -n "$(git status --porcelain)" ]; then
  revision="$revision (with uncommitted changes: not a release build)"
fi
cat > "$stage/Source.txt" <<EOF
Custodrive $version is free software under GPL-2.0-or-later (see License.txt).
It includes NTFS-3G 2026.7.7 by Tuxera, also under GPL-2.0-or-later.

Complete source code: https://github.com/nicomil/custodrive
Source revision of this package: $revision
EOF

dmg="$project_dir/Build/Custodrive-$version.dmg"
rm -f "$dmg"
hdiutil create -quiet -volname "Custodrive $version" -srcfolder "$stage" -fs HFS+ \
  -format UDZO -imagekey zlib-level=9 "$dmg"
hdiutil verify -quiet "$dmg"
shasum -a 256 "$dmg" | awk '{print $1}' > "$dmg.sha256"
printf 'Package: %s (%s)\n' "$dmg" "$(du -h "$dmg" | awk '{print $1}')"
