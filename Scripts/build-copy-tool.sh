#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PROJECT_DIR="$project_dir" "$project_dir/Scripts/build-ntfs3g.sh"

test_flag=
output="$project_dir/Build/OpenHDDCopy"
if [ "${OPENHDD_TESTING:-0}" = 1 ]; then
  test_flag=-DOPENHDD_TESTING
  output="$project_dir/Build/OpenHDDCopyTest"
fi

cc -std=c11 -O2 -arch arm64 -mmacosx-version-min=15.4 \
  -Wall -Wextra -Werror $test_flag \
  -I "$project_dir/Sources/NTFSBridge/include" \
  -I "$project_dir/Sources/NTFSWrite" \
  -I "$project_dir/vendor/ntfs-3g-2026.7.7/include" \
  -I "$project_dir/Build/ntfs3g" \
  "$project_dir/Sources/NTFSBridge/OpenHDDNTFS.c" \
  "$project_dir/Sources/NTFSWrite/WriteEngine.c" \
  "$project_dir/Sources/NTFSWrite/OpenHDDCopy.c" \
  "$project_dir/Build/ntfs3g/libntfs-3g/.libs/libntfs-3g.a" \
  -framework CoreFoundation -framework DiskArbitration -framework IOKit -framework Security \
  -o "$output"

cc -std=c11 -O2 -arch arm64 -mmacosx-version-min=15.4 \
  -Wall -Wextra -Werror \
  "$project_dir/Sources/NTFSWrite/MarkNTFSPartition.c" \
  -o "$project_dir/Build/MarkNTFSPartition"
