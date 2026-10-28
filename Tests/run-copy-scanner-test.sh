#!/bin/sh
# Checks how a copy is compared with the disk, without any disk.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/custodrive-scanner.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$work/cache" -D OPENHDD_LOCAL \
  "$root/Sources/OpenHDDApp/NTFSCopy.swift" "$root/Sources/OpenHDDApp/NTFSSession.swift" \
  "$root/Sources/OpenHDDApp/Localization.swift" \
  "$root/Tests/copy_scanner_test.swift" -o "$work/copy-scanner-test"
"$work/copy-scanner-test"
