#!/bin/sh
# Build the no-membership, native-read-only macOS app.
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
codesign --force --sign - --timestamp=none "$output"
codesign --verify --strict "$output"
printf 'Ready: %s\n' "$output"
