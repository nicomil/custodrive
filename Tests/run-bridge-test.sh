#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
mkdir -p "$build"
if [ ! -f "$build/Makefile" ]; then
  (cd "$build" && "$root/vendor/ntfs-3g-2026.7.7/configure" --disable-ntfs-3g \
    --enable-ntfsprogs --disable-plugins --disable-crypto \
    --enable-static --disable-shared > configure.log)
fi
make -C "$build/libntfs-3g" -j4 > "$build/make.log"
make -C "$build/ntfsprogs" mkntfs ntfscp ntfsfix -j4 > "$build/tools.log"
cc -std=c11 -Wall -Wextra -Werror \
  -I "$root/Sources/NTFSBridge/include" \
  -I "$root/vendor/ntfs-3g-2026.7.7/include" -I "$build" \
  "$root/Sources/NTFSBridge/OpenHDDNTFS.c" "$root/Tests/bridge_test.c" \
  "$build/libntfs-3g/.libs/libntfs-3g.a" -framework CoreFoundation \
  -o "$build/bridge_test"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/open-hdd-fixture.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
image="$fixture/ntfs.img"
mkfile -n 64m "$image"
"$build/ntfsprogs/mkntfs" -F -Q -L OpenHDDTest "$image" > "$fixture/mkntfs.log"
printf 'OpenHDD safe read test\n' > "$fixture/known.txt"
touch "$fixture/empty.txt"
printf 'café' > "$fixture/unicode.txt"
dd if=/dev/urandom of="$fixture/large.bin" bs=1m count=2 status=none
"$build/ntfsprogs/ntfscp" "$image" "$fixture/known.txt" /known.txt
"$build/ntfsprogs/ntfscp" "$image" "$fixture/empty.txt" /empty.txt
"$build/ntfsprogs/ntfscp" "$image" "$fixture/unicode.txt" /café.txt
"$build/ntfsprogs/ntfscp" "$image" "$fixture/large.bin" /large.bin
before=$(shasum -a 256 "$image" | awk '{print $1}')
"$build/bridge_test" "$image" "$fixture/large.bin"
after=$(shasum -a 256 "$image" | awk '{print $1}')
test "$before" = "$after"
hiber_image="$fixture/hibernated.img"
cp "$image" "$hiber_image"
dd if=/dev/zero of="$fixture/hiberfil.sys" bs=4096 count=1 status=none
printf hibr | dd of="$fixture/hiberfil.sys" conv=notrunc status=none
"$build/ntfsprogs/ntfscp" "$hiber_image" "$fixture/hiberfil.sys" /hiberfil.sys
hiber_before=$(shasum -a 256 "$hiber_image" | awk '{print $1}')
"$build/bridge_test" "$hiber_image" "$fixture/large.bin" --expect-hibernated
hiber_after=$(shasum -a 256 "$hiber_image" | awk '{print $1}')
test "$hiber_before" = "$hiber_after"
"$build/ntfsprogs/ntfsfix" "$image" > "$fixture/ntfsfix.log"
dirty_before=$(shasum -a 256 "$image" | awk '{print $1}')
"$build/bridge_test" "$image" "$fixture/large.bin" --expect-dirty
dirty_after=$(shasum -a 256 "$image" | awk '{print $1}')
test "$dirty_before" = "$dirty_after"
mkfile -n 64m "$fixture/not-ntfs.img"
"$build/bridge_test" "$fixture/not-ntfs.img" --reject
echo "PASS: contenuti, hash invariati con dirty bit e ibernazione simulata, non-NTFS rifiutato, zero scritture"
