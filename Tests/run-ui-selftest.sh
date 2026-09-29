#!/bin/sh
# In-app test of the Finder-like browser on a disposable NTFS disk image:
# builds OpenHDD Local with OPENHDD_UI_SELFTEST, attaches a fresh image, and
# lets the app drive its own table (drop from the Finder, drag between
# folders, refusals), the edit session and Quick Look, then checks the image.
#
# Usage: Tests/run-ui-selftest.sh RAW_DISK_IMAGE_WITH_ONE_NTFS_PARTITION
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_image=$1
work=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-ui.XXXXXX")
disk=
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  [ -z "$disk" ] || hdiutil detach "$disk" >/dev/null 2>&1 || true
  # The test build must not stay registered next to the real app.
  "$lsregister" -u "$work/OpenHDDSelfTest.app" >/dev/null 2>&1 || true
  "$lsregister" -u "$root/Build/DerivedDataSelfTest/Build/Products/Release/Custodrive.app" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

cd "$root"
xcodegen generate >/dev/null
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -quiet -project OpenHDD.xcodeproj -scheme OpenHDDLocal -configuration Release \
  -derivedDataPath Build/DerivedDataSelfTest CODE_SIGNING_ALLOWED=NO \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OPENHDD_LOCAL OPENHDD_UI_SELFTEST' build
app="$work/OpenHDDSelfTest.app"
ditto Build/DerivedDataSelfTest/Build/Products/Release/Custodrive.app "$app"
Scripts/build-copy-tool.sh >/dev/null
install -m 755 Build/OpenHDDCopy "$app/Contents/Resources/OpenHDDCopy"
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1

cp "$source_image" "$work/disk.img"
disk=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage "$work/disk.img" 2>/dev/null |
  awk '/Windows_NTFS/ {print $1}' | sed 's|/dev/||; s|s1$||')
[ -n "$disk" ] || fail "image did not attach"
label=$(diskutil info "${disk}s1" | awk -F': *' '/Volume Name/ {print $2}')

src="$work/Scatti"
mkdir -p "$src"
sips -s format png /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFolderIcon.icns \
  --out "$src/foto 1.png" >/dev/null
printf 'nota è\n' > "$src/nota.txt"

osascript -e 'tell application id "app.custodrive.mac" to quit' >/dev/null 2>&1 || true
sleep 1
OPENHDD_UI_SELFTEST_DISK="$label" OPENHDD_UI_SELFTEST_REPORT="$work/report.txt" \
OPENHDD_UI_SELFTEST_SOURCE="$src" "$app/Contents/MacOS/Custodrive" >"$work/app.log" 2>&1 &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 240 ]; do sleep 1; waited=$((waited + 1)); done
kill "$pid" 2>/dev/null || true
[ -f "$work/report.txt" ] || { cat "$work/report.txt.partial" 2>/dev/null; grep -v '^20..-' "$work/app.log" | tail -20; fail "no report (timed out after ${waited}s)"; }
cat "$work/report.txt"
grep -q '^FAIL' "$work/report.txt" && fail "in-app steps failed"

# The volume the app left behind: clean, no temporaries, contents right.
mount=$(diskutil info "${disk}s1" | awk -F': *' '/Mount Point/ {print $2}')
[ -n "$mount" ] || fail "volume not remounted"
cmp -s "$mount/Documenti/Scatti/foto 1.png" "$src/foto 1.png" || fail "copied image differs"
cmp -s "$mount/Documenti/Scatti/nota.txt" "$src/nota.txt" || fail "copied note differs"
[ -f "$mount/Documenti/old.bin" ] && [ ! -e "$mount/old.bin" ] || fail "move not applied"
hdiutil detach "$disk" >/dev/null
disk=
geometry=$(python3 -c "import struct;d=open('$work/disk.img','rb').read(512);print(*struct.unpack('<II',d[454:462]))")
dd if="$work/disk.img" of="$work/p.img" bs=512 skip="${geometry% *}" count="${geometry#* }" status=none
chmod 600 "$work/p.img"
OPENHDD_TESTING=1 Scripts/build-copy-tool.sh >/dev/null
Build/OpenHDDCopyTest --check-image "$work/p.img" | grep -q '^dirty=0 .* pending=0 code=0' ||
  fail "volume not clean: $(Build/OpenHDDCopyTest --check-image "$work/p.img")"
echo 'PASS: in-app drop from the Finder, drag between folders, refusals, edit session, Quick Look; volume clean, contents verified'
