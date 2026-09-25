#!/bin/sh
set -eu
root=${PROJECT_DIR:?}
build="$root/Build/ntfs3g"
source="$root/vendor/ntfs-3g-2026.7.7"
archive="$root/vendor/ntfs-3g_ntfsprogs-2026.7.7.tgz"
expected=d67b769025d32860549d35c2147e45024d172f81c540d750390ce3602c059dab
actual=$(shasum -a 256 "$archive" | awk '{print $1}')
test "$actual" = "$expected" || { echo "NTFS-3G archive checksum mismatch" >&2; exit 1; }
check=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-vendor.XXXXXX")
trap 'rm -rf "$check"' EXIT HUP INT TERM
tar -xzf "$archive" -C "$check"
diff -qr "$source" "$check/ntfs-3g-2026.7.7" >/dev/null || {
  echo "NTFS-3G extracted source differs from verified archive" >&2
  exit 1
}
export MACOSX_DEPLOYMENT_TARGET=15.4
export CFLAGS="-O2 -arch arm64 -mmacosx-version-min=15.4"
mkdir -p "$build"
if [ ! -f "$build/Makefile" ]; then
  (cd "$build" && "$source/configure" --disable-ntfs-3g \
    --disable-ntfsprogs --disable-plugins --disable-crypto \
    --enable-static --disable-shared > configure.log)
fi
make -C "$build/libntfs-3g" -j4 > "$build/build.log"
test -s "$build/libntfs-3g/.libs/libntfs-3g.a"
