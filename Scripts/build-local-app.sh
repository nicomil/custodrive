#!/bin/sh
# Build the no-membership macOS app: native NTFS reading plus verified copies.
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"

xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -quiet -project OpenHDD.xcodeproj -scheme OpenHDDLocal \
  -configuration Release -derivedDataPath Build/DerivedData \
  CODE_SIGNING_ALLOWED=NO build

output="$project_dir/Build/OpenHDDLocal.app"
rm -rf "$output"
ditto "$project_dir/Build/DerivedData/Build/Products/Release/OpenHDDLocal.app" "$output"
# The copy engine runs as a separate tool so that only it ever needs
# administrator rights, and only for the duration of one copy.
"$project_dir/Scripts/build-copy-tool.sh"
mkdir -p "$output/Contents/Resources"
install -m 755 "$project_dir/Build/OpenHDDCopy" "$output/Contents/Resources/OpenHDDCopy"
codesign --force --sign - --timestamp=none --options runtime \
  "$output/Contents/Resources/OpenHDDCopy"
codesign --force --sign - --timestamp=none "$output"
codesign --verify --strict "$output"
printf 'Ready: %s\n' "$output"
