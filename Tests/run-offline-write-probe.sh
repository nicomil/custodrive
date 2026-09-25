#!/bin/sh
# Feasibility probe only. Never accepts a physical device or a caller path as NTFS target.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${TMPDIR:-/tmp}/open-hdd-bridge-test

# Reuse the same upstream build configuration as the read-only bridge tests.
if [ ! -f "$build/Makefile" ]; then
  mkdir -p "$build"
  (cd "$build" && "$root/vendor/ntfs-3g-2026.7.7/configure" \
    --disable-ntfs-3g --enable-ntfsprogs --disable-plugins --disable-crypto \
    --enable-static --disable-shared > configure.log)
fi
make -C "$build/libntfs-3g" -j4 > "$build/make.log"
make -C "$build/ntfsprogs" mkntfs ntfscp ntfscat ntfsfix -j4 > "$build/write-tools.log"
cc -std=c11 -Wall -Wextra -Werror \
  -I "$root/Sources/NTFSBridge/include" \
  -I "$root/vendor/ntfs-3g-2026.7.7/include" -I "$build" \
  "$root/Sources/NTFSBridge/OpenHDDNTFS.c" \
  "$root/Tests/offline_image_writer.c" \
  "$build/libntfs-3g/.libs/libntfs-3g.a" -framework CoreFoundation \
  -o "$build/offline_image_writer"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/open-hdd-write-probe.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
image="$fixture/ntfs.img"
source_file="$fixture/source.bin"
readback="$fixture/readback.bin"

mkfile -n 64m "$image"
chmod 600 "$image"
"$build/ntfsprogs/mkntfs" -F -Q -L OpenHDDProbe "$image" > "$fixture/mkntfs.log" 2>&1
dd if=/dev/urandom of="$source_file" bs=1m count=2 status=none
"$build/offline_image_writer" "$image" "$source_file" created.bin
"$build/ntfsprogs/ntfscat" "$image" /created.bin > "$readback"
cmp "$source_file" "$readback"
printf 'café\n' > "$fixture/unicode.txt"
"$build/offline_image_writer" "$image" "$fixture/unicode.txt" café.txt
touch "$fixture/empty.txt"
"$build/offline_image_writer" "$image" "$fixture/empty.txt" empty.txt

before=$(shasum -a 256 "$image" | awk '{print $1}')
if "$build/offline_image_writer" "$image" "$source_file" created.bin > "$fixture/exists.log" 2>&1; then
  echo 'FAIL: duplicate filename accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$image" | awk '{print $1}')
test "$before" = "$after"

dirty="$fixture/dirty.img"
cp "$image" "$dirty"
"$build/ntfsprogs/ntfsfix" "$dirty" > "$fixture/ntfsfix.log"
before=$(shasum -a 256 "$dirty" | awk '{print $1}')
if "$build/offline_image_writer" "$dirty" "$source_file" should-not-exist.bin > "$fixture/dirty.log" 2>&1; then
  echo 'FAIL: dirty volume accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$dirty" | awk '{print $1}')
test "$before" = "$after"

hibernated="$fixture/hibernated.img"
cp "$image" "$hibernated"
printf hibr > "$fixture/hiberfil.sys"
"$build/ntfsprogs/ntfscp" "$hibernated" "$fixture/hiberfil.sys" /hiberfil.sys > "$fixture/hiber-fixture.log" 2>&1
before=$(shasum -a 256 "$hibernated" | awk '{print $1}')
if "$build/offline_image_writer" "$hibernated" "$source_file" should-not-exist.bin > "$fixture/hibernated.log" 2>&1; then
  echo 'FAIL: hibernated volume accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$hibernated" | awk '{print $1}')
test "$before" = "$after"

interrupted="$fixture/interrupted.img"
cp "$image" "$interrupted"
if OPENHDD_TEST_FAIL_AFTER_FIRST_CHUNK=1 "$build/offline_image_writer" \
  "$interrupted" "$source_file" partial.bin > "$fixture/interrupted.log" 2>&1; then
  echo 'FAIL: injected write error reported success' >&2
  exit 1
fi

not_ntfs="$fixture/not-ntfs.img"
mkfile -n 64m "$not_ntfs"
chmod 600 "$not_ntfs"
before=$(shasum -a 256 "$not_ntfs" | awk '{print $1}')
if "$build/offline_image_writer" "$not_ntfs" "$source_file" should-not-exist.bin > "$fixture/non-ntfs.log" 2>&1; then
  echo 'FAIL: non-NTFS image accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$not_ntfs" | awk '{print $1}')
test "$before" = "$after"

echo "PASS: image-only write/readback; duplicate, dirty, hibernated and non-NTFS rejected; injected error reported"
echo "This is not a physical-disk or power-loss safety test."
