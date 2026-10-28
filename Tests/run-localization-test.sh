#!/bin/sh
# Run after Scripts/build-local-app.sh; verifies the shipped catalogs.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/custodrive-localization.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
xcrun swiftc -module-cache-path "$work/cache" \
  "$root/Sources/OpenHDDApp/Localization.swift" "$root/Tests/localization_test.swift" \
  -o "$work/localization-test"
"$work/localization-test" "${1:-$root/Build/Custodrive.app}"
