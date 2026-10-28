#!/bin/sh
# Regenerates the README screenshots in docs/images/{en,it,es}/ from the
# current source: builds the test variant of the app, attaches disposable
# NTFS disk images with localized names, and lets the app walk through the
# README scenes in each language (Sources/OpenHDDApp/ReadmeShots.swift).
#
# Usage: Scripts/readme-screenshots.sh [en it es]
# Needs the bridge test tools (sh Tests/run-bridge-test.sh builds them).
# The windows come to the front while each language is captured.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
languages=${*:-en it es}
work=$(mktemp -d "${TMPDIR:-/tmp}/custodrive-shots.XXXXXX")
chmod 700 "$work"
disks=
lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
cleanup() {
  for disk in $disks; do hdiutil detach "$disk" >/dev/null 2>&1 || true; done
  "$lsregister" -u "$work/CustodriveShots.app" >/dev/null 2>&1 || true
  "$lsregister" -u "$root/Build/DerivedDataSelfTest/Build/Products/Release/Custodrive.app" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM
fail() { echo "FAIL: $*" >&2; exit 1; }

mkntfs=${TMPDIR:-/tmp}/open-hdd-bridge-test/ntfsprogs/mkntfs
[ -x "$mkntfs" ] || "$root/Tests/run-bridge-test.sh" >/dev/null
cd "$root"
OPENHDD_TESTING=1 Scripts/build-copy-tool.sh >/dev/null
xcodegen generate >/dev/null
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -quiet -project OpenHDD.xcodeproj -scheme OpenHDDLocal -configuration Release \
  -derivedDataPath Build/DerivedDataSelfTest CODE_SIGNING_ALLOWED=NO \
  PRODUCT_BUNDLE_IDENTIFIER=app.custodrive.selftest \
  SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) OPENHDD_LOCAL OPENHDD_UI_SELFTEST' build \
  2>&1 | grep -E ': error: ' && fail "build"
app="$work/CustodriveShots.app"
ditto Build/DerivedDataSelfTest/Build/Products/Release/Custodrive.app "$app"
Scripts/build-copy-tool.sh >/dev/null
install -m 755 Build/OpenHDDCopy "$app/Contents/Resources/OpenHDDCopy"
codesign --force --sign - --timestamp=none "$app" >/dev/null 2>&1

for language in $languages; do
  case $language in
    en) locale=en_US ;; it) locale=it_IT ;; es) locale=es_ES ;; *) fail "unknown language $language" ;;
  esac
  python3 -I Scripts/readme-disks.py "$work" "$mkntfs" "$root/Build/OpenHDDCopyTest" "$language"
  disks=
  for image in archive backup; do
    disk=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage "$work/$language-$image.img" |
      awk '/Windows_NTFS/ {print $1}' | sed 's|/dev/||; s|s1$||')
    [ -n "$disk" ] || fail "$language-$image did not attach"
    disks="$disks $disk"
  done
  # Language and region only for this launch: the user's settings stay as they are.
  OPENHDD_README_SHOTS="$work/$language-plan.json" "$app/Contents/MacOS/Custodrive" \
    -CustodriveLanguage "$language" -AppleLocale "$locale" -AppleLanguages "($language)" \
    >"$work/$language.log" 2>&1 || true
  grep -q 'README shots written' "$work/$language.log" || { tail -5 "$work/$language.log"; fail "$language tour"; }
  for disk in $disks; do hdiutil detach "$disk" >/dev/null; done
  disks=
  mkdir -p "docs/images/$language"
  cp "$work/shots-$language"/*.png "docs/images/$language/"
  echo "docs/images/$language: $(ls "docs/images/$language" | tr '\n' ' ')"
done
