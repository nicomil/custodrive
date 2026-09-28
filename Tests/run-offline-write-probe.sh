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
make -C "$build/ntfsprogs" mkntfs ntfscp ntfscat ntfsfix ntfsinfo ntfscluster ntfsls ntfsrecover -j4 > "$build/write-tools.log"
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

# Cache/persistence simulator: only a private image is accepted. Every write
# is acknowledged into volatile cache; every third write reaches stable image
# storage, then a synthetic power loss drops the remaining cache. Trace contains
# offsets and byte counts only, never source contents or filenames.
cache_base="$fixture/cache-base.img"
mkfile -n 128m "$cache_base"
chmod 600 "$cache_base"
"$build/ntfsprogs/mkntfs" -F -Q -L CacheProbe "$cache_base" > "$fixture/cache-mkntfs.log" 2>&1
bitmap_free_before=$("$build/ntfsprogs/ntfsinfo" -m "$cache_base" |
  awk '/Free Clusters:/ {print $3; exit}')
owner_free_before=$("$build/ntfsprogs/ntfscluster" -i "$cache_base" |
  awk '/clusters of free space/ {print $6; exit}')
mft_records_before=$("$build/ntfsprogs/ntfscluster" -i "$cache_base" |
  awk '/mft records in use/ {print $6; exit}')
bitmap_lcn=$("$build/ntfsprogs/ntfscluster" -I 6 "$cache_base" |
  awk '$1 == "0" && $2 ~ /^[0-9]+$/ {print $2; exit}')
cluster_bytes=$("$build/ntfsprogs/ntfscluster" -i "$cache_base" |
  awk '/bytes per cluster/ {print $5; exit}')
bitmap_write_offset=$((bitmap_lcn * cluster_bytes + 1))
test "$bitmap_free_before" = "$owner_free_before"

powercut="$fixture/powercut-bitmap.img"
cp "$cache_base" "$powercut"
set +e
OPENHDD_SIMULATE_CACHE=1 OPENHDD_SIM_PERSIST_EVERY=3 \
  OPENHDD_SIM_CRASH_AFTER_PWRITE=3 OPENHDD_SIM_TRACE="$fixture/powercut.trace" \
  "$build/offline_image_writer" "$powercut" "$source_file" lost.bin \
  > "$fixture/powercut.log" 2>&1
powercut_result=$?
set -e
test "$powercut_result" -eq 86
grep -q "ACCEPT write=3 offset=$bitmap_write_offset length=$((cluster_bytes - 1))" "$fixture/powercut.trace"
grep -q 'PERSIST write=3 bytes=4095' "$fixture/powercut.trace"
grep -q 'POWER_LOSS after-write=3' "$fixture/powercut.trace"
bitmap_free_after=$("$build/ntfsprogs/ntfsinfo" -m "$powercut" |
  awk '/Free Clusters:/ {print $3; exit}')
owner_free_after=$("$build/ntfsprogs/ntfscluster" -i "$powercut" |
  awk '/clusters of free space/ {print $6; exit}')
mft_records_after=$("$build/ntfsprogs/ntfscluster" -i "$powercut" |
  awk '/mft records in use/ {print $6; exit}')
test "$bitmap_free_after" -lt "$owner_free_after"
test "$mft_records_after" = "$mft_records_before"
if "$build/ntfsprogs/ntfsls" -a -l -i -p / "$powercut" |
  grep -q 'lost.bin'; then
  echo 'FAIL: power-cut test published the new name' >&2
  exit 1
fi
set +e
"$build/ntfsprogs/ntfsrecover" -n -t "$powercut" > "$fixture/powercut-recovery.log" 2>&1
recovery_result=$?
set -e
test "$recovery_result" -ne 0
grep -Eqi 'log file has been wiped out' "$fixture/powercut-recovery.log"

# Torn persistence: device acknowledges all 4095 bytes but only 512 become
# durable before power is lost. The trace distinguishes accepted from stable.
partial="$fixture/powercut-partial.img"
cp "$cache_base" "$partial"
set +e
OPENHDD_SIMULATE_CACHE=1 OPENHDD_SIM_PARTIAL_PERSIST_AT=3 \
  OPENHDD_SIM_PARTIAL_PERSIST_BYTES=512 OPENHDD_SIM_CRASH_AFTER_PWRITE=3 \
  OPENHDD_SIM_TRACE="$fixture/partial.trace" \
  "$build/offline_image_writer" "$partial" "$source_file" partial.bin \
  > "$fixture/partial.log" 2>&1
partial_result=$?
set -e
test "$partial_result" -eq 86
grep -q "ACCEPT write=3 offset=$bitmap_write_offset length=$((cluster_bytes - 1))" "$fixture/partial.trace"
grep -q 'PERSIST write=3 bytes=512' "$fixture/partial.trace"
grep -q 'POWER_LOSS after-write=3' "$fixture/partial.trace"

# A reverse persistence order must never be reported as a successful copy.
reverse_base="$fixture/reverse-base.img"
cp "$cache_base" "$reverse_base"
"$build/offline_image_writer" "$reverse_base" "$source_file" existing.bin \
  > "$fixture/reverse-prepare.log"
reverse="$fixture/reverse-flush.img"
cp "$reverse_base" "$reverse"
set +e
OPENHDD_SIMULATE_CACHE=1 OPENHDD_SIM_FLUSH_ORDER=reverse \
  OPENHDD_SIM_TRACE="$fixture/reverse.trace" \
  "$build/offline_image_writer" "$reverse" "$source_file" reordered.bin \
  > "$fixture/reverse.log" 2>&1
reverse_result=$?
set -e
test "$reverse_result" -ne 0
if grep -q 'PASS:' "$fixture/reverse.log"; then
  echo 'FAIL: reverse persistence order reported success' >&2
  exit 1
fi
grep -q 'order=reverse' "$fixture/reverse.trace"
"$build/ntfsprogs/ntfscat" "$reverse" /existing.bin > "$fixture/existing-after-reorder.bin"
cmp "$source_file" "$fixture/existing-after-reorder.bin"

# Interrupt while a reverse-ordered sync is persisting its first block.
mid_sync="$fixture/powercut-during-sync.img"
cp "$cache_base" "$mid_sync"
set +e
OPENHDD_SIMULATE_CACHE=1 OPENHDD_SIM_FLUSH_ORDER=reverse \
  OPENHDD_SIM_CRASH_DURING_SYNC_AFTER=1 \
  OPENHDD_SIM_TRACE="$fixture/mid-sync.trace" \
  "$build/offline_image_writer" "$mid_sync" "$source_file" sync-cut.bin \
  > "$fixture/mid-sync.log" 2>&1
mid_sync_result=$?
set -e
test "$mid_sync_result" -eq 86
grep -q 'POWER_LOSS during-sync=1 after=1' "$fixture/mid-sync.trace"

if [ "${OPENHDD_PRESERVE_POWERLOSS_ARTIFACTS:-0}" = "1" ]; then
  preserved="$root/Build/evidence/powerloss-sim-20260927"
  mkdir -p "$root/Build/evidence"
  mkdir -m 700 "$preserved"
  cp -c "$cache_base" "$preserved/cache-base.img"
  cp -c "$powercut" "$preserved/powercut-bitmap.img"
  cp -c "$fixture/powercut.trace" "$preserved/powercut.trace"
  cp -c "$partial" "$preserved/powercut-partial.img"
  cp -c "$fixture/partial.trace" "$preserved/powercut-partial.trace"
  cp -c "$reverse" "$preserved/reverse-flush.img"
  cp -c "$fixture/reverse.trace" "$preserved/reverse-flush.trace"
  cp -c "$mid_sync" "$preserved/powercut-during-sync.img"
  cp -c "$fixture/mid-sync.trace" "$preserved/powercut-during-sync.trace"
  chmod 600 "$preserved"/*
  shasum -a 256 "$preserved"/*.img > "$preserved/SHA256SUMS"
  chmod 600 "$preserved/SHA256SUMS"
fi

echo "PASS: image-only writes, volatile/durable cache, deterministic power cuts, partial persistence, reverse flush, mid-sync interruption; existing file retained and no false PASS"
echo "The simulator is not a physical-device test or a Windows journal-recovery pass."
