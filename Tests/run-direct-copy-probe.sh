#!/bin/sh
# Tests the fd-bound copy engine on disposable regular-file images only.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
"$root/Scripts/build-copy-tool.sh"
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
if [ ! -x "$build/ntfsprogs/mkntfs" ]; then
  "$root/Tests/run-offline-write-probe.sh" >/dev/null
fi
fixture=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-direct-copy.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

image="$fixture/ntfs.img"
source_file="$fixture/source.bin"
mkfile -n 128m "$image"
chmod 600 "$image"
"$build/ntfsprogs/mkntfs" -F -Q -L DirectProbe "$image" > "$fixture/mkntfs.log" 2>&1
mkdir -m 700 "$fixture/quarantine"
cc -std=c11 -O2 -arch arm64 -mmacosx-version-min=15.4 -Wall -Wextra -Werror \
  -I "$root/Sources/NTFSBridge/include" \
  -I "$root/Sources/NTFSWrite" \
  -I "$root/vendor/ntfs-3g-2026.7.7/include" \
  -I "$root/Build/ntfs3g" \
  "$root/Sources/NTFSBridge/OpenHDDNTFS.c" \
  "$root/Sources/NTFSWrite/WriteEngine.c" \
  "$root/Tests/quarantine_probe.c" \
  "$root/Build/ntfs3g/libntfs-3g/.libs/libntfs-3g.a" \
  -framework CoreFoundation -framework DiskArbitration -framework IOKit -framework Security \
  -o "$fixture/quarantine-probe"
"$fixture/quarantine-probe" "$image" "$fixture/quarantine"
dd if=/dev/urandom of="$source_file" bs=1m count=8 status=none
if "$root/Build/OpenHDDCopy" --disk disk999s1 "$source_file" denied.bin > "$fixture/physical-lockout.log" 2>&1; then
  echo 'FAIL: production binary accepted an unknown partition' >&2
  exit 1
fi
grep -q 'not an external NTFS partition' "$fixture/physical-lockout.log"
if "$root/Build/OpenHDDCopyTest" --disk disk999s1 "$source_file" denied.bin > "$fixture/test-disk.log" 2>&1; then
  echo 'FAIL: test binary accepted a physical disk' >&2
  exit 1
fi
grep -q 'Test binary accepts private images only' "$fixture/test-disk.log"
before=$(shasum -a 256 "$image" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$image" "$source_file" invalid.bin. > "$fixture/invalid-name.log" 2>&1; then
  echo 'FAIL: trailing dot accepted in destination name' >&2
  exit 1
fi
grep -q 'invalid new file name' "$fixture/invalid-name.log"
after=$(shasum -a 256 "$image" | awk '{print $1}')
test "$before" = "$after"
"$root/Build/OpenHDDCopyTest" --image "$image" "$source_file" verified.bin
"$build/ntfsprogs/ntfscat" -f "$image" /verified.bin > "$fixture/readback.bin"
cmp "$source_file" "$fixture/readback.bin"
make -C "$build/ntfsprogs" ntfsls >/dev/null
if "$build/ntfsprogs/ntfsls" -f -l -a -p / "$image" | grep -q '\.OpenHDD-pending-'; then
  echo 'FAIL: successful copy left an uncertain temporary name' >&2
  exit 1
fi

touch "$fixture/empty.bin"
"$root/Build/OpenHDDCopyTest" --image "$image" "$fixture/empty.bin" empty.bin
"$build/ntfsprogs/ntfscat" -f "$image" /empty.bin > "$fixture/empty-readback.bin"
test ! -s "$fixture/empty-readback.bin"

# File lengths around the copy chunk, including an empty data stream.
printf x > "$fixture/one.bin"
printf '\303\251\344\270\255\360\237\214\215\n' > "$fixture/unicode.bin"
for size in 65535 65536 65537; do
  mkfile -n "$size" "$fixture/boundary-$size.bin"
  dd if="$fixture/unicode.bin" of="$fixture/boundary-$size.bin" \
    conv=notrunc status=none
done
for name in one boundary-65535 boundary-65536 boundary-65537; do
  "$root/Build/OpenHDDCopyTest" --image "$image" "$fixture/$name.bin" "$name.bin"
  "$build/ntfsprogs/ntfscat" -f "$image" "/$name.bin" > "$fixture/$name-readback.bin"
  cmp "$fixture/$name.bin" "$fixture/$name-readback.bin"
done

# Short system calls must be retried; a short write followed by EIO must fail.
OPENHDD_TEST_SHORT_PREAD_AT=1 OPENHDD_TEST_SHORT_PWRITE_AT=1 \
  "$root/Build/OpenHDDCopyTest" --image "$image" \
  "$fixture/boundary-65537.bin" short-io.bin
"$build/ntfsprogs/ntfscat" -f "$image" /short-io.bin > "$fixture/short-io-readback.bin"
cmp "$fixture/boundary-65537.bin" "$fixture/short-io-readback.bin"
partial_io="$fixture/partial-io.img"
cp "$image" "$partial_io"
if OPENHDD_TEST_SHORT_PWRITE_AT=8 OPENHDD_TEST_FAIL_PWRITE_AT=9 \
  "$root/Build/OpenHDDCopyTest" --image "$partial_io" \
  "$source_file" short-then-error.bin > "$fixture/partial-io.log" 2>&1; then
  echo 'FAIL: short write followed by EIO reported success' >&2
  exit 1
fi
grep -q 'Copy failed' "$fixture/partial-io.log"
"$build/ntfsprogs/ntfscat" -f "$partial_io" /verified.bin > "$fixture/partial-old.bin"
cmp "$source_file" "$fixture/partial-old.bin"
read_error="$fixture/short-read-error.img"
cp "$image" "$read_error"
before=$(shasum -a 256 "$read_error" | awk '{print $1}')
if OPENHDD_TEST_SHORT_PREAD_AT=1 OPENHDD_TEST_FAIL_PREAD_AT=2 \
  "$root/Build/OpenHDDCopyTest" --image "$read_error" \
  "$source_file" short-read-error.bin > "$fixture/short-read-error.log" 2>&1; then
  echo 'FAIL: short read followed by EIO reported success' >&2
  exit 1
fi
after=$(shasum -a 256 "$read_error" | awk '{print $1}')
test "$before" = "$after"

before=$(shasum -a 256 "$image" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$image" "$source_file" verified.bin > "$fixture/duplicate.log" 2>&1; then
  echo 'FAIL: duplicate destination accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$image" | awk '{print $1}')
test "$before" = "$after"

ln -s "$source_file" "$fixture/source-link"
if "$root/Build/OpenHDDCopyTest" --image "$image" "$fixture/source-link" link.bin > "$fixture/symlink.log" 2>&1; then
  echo 'FAIL: source symlink accepted' >&2
  exit 1
fi

dirty="$fixture/dirty.img"
cp "$image" "$dirty"
"$build/ntfsprogs/ntfsfix" "$dirty" > "$fixture/ntfsfix.log"
before=$(shasum -a 256 "$dirty" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$dirty" "$source_file" dirty.bin > "$fixture/dirty.log" 2>&1; then
  echo 'FAIL: dirty volume accepted' >&2
  exit 1
fi
grep -q 'NTFS safety preflight refused: dirty volume;' "$fixture/dirty.log"
after=$(shasum -a 256 "$dirty" | awk '{print $1}')
test "$before" = "$after"

interrupted="$fixture/interrupted.img"
cp "$image" "$interrupted"
if OPENHDD_TEST_FAIL_AFTER_FIRST_CHUNK=1 \
  "$root/Build/OpenHDDCopyTest" --image "$interrupted" "$source_file" partial.bin > "$fixture/interrupted.log" 2>&1; then
  echo 'FAIL: write interruption reported success' >&2
  exit 1
fi
if "$build/ntfsprogs/ntfscat" -f "$interrupted" /partial.bin > "$fixture/partial-readback.bin" 2>/dev/null; then
  echo 'FAIL: incomplete file published at final name' >&2
  exit 1
fi

# A process exit skips inode close, unmount and sync; this is not a power-cut test.
crashed="$fixture/crashed.img"
"$build/ntfsprogs/ntfsls" -f -l -a -p / "$image" | \
  awk '/\.OpenHDD-pending-/ {print $NF}' | sort > "$fixture/pending-before.txt"
cp "$image" "$crashed"
set +e
OPENHDD_TEST_ABORT_AFTER_FIRST_CHUNK=1 \
  "$root/Build/OpenHDDCopyTest" --image "$crashed" "$source_file" crashed.bin > "$fixture/crashed.log" 2>&1
crash_code=$?
set -e
test "$crash_code" -eq 86
before=$(shasum -a 256 "$crashed" | awk '{print $1}')
"$build/ntfsprogs/ntfsfix" -n "$crashed" > "$fixture/crash-check.log" 2>&1
"$build/ntfsprogs/ntfsls" -f -l -a -p / "$crashed" | \
  awk '/\.OpenHDD-pending-/ {print $NF}' | sort > "$fixture/pending-after.txt"
pending=$(comm -13 "$fixture/pending-before.txt" "$fixture/pending-after.txt")
test -n "$pending"
test "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')" -eq 1
"$build/ntfsprogs/ntfscat" -f "$crashed" "/$pending" > "$fixture/crash-pending.bin"
cmp -n 65536 "$source_file" "$fixture/crash-pending.bin"
if cmp -s "$source_file" "$fixture/crash-pending.bin"; then
  echo 'FAIL: crash probe did not interrupt the copy' >&2
  exit 1
fi
if "$build/ntfsprogs/ntfscat" -f "$crashed" /crashed.bin > "$fixture/crash-final.bin" 2>/dev/null; then
  echo 'FAIL: crash published incomplete file' >&2
  exit 1
fi
after=$(shasum -a 256 "$crashed" | awk '{print $1}')
test "$before" = "$after"
if "$root/Build/OpenHDDCopyTest" --image "$crashed" "$source_file" retry.bin > "$fixture/crash-retry.log" 2>&1; then
  echo 'FAIL: copy accepted orphaned pending file after crash' >&2
  exit 1
fi
grep -q 'Refused: unfinished OpenHDD transfer found' "$fixture/crash-retry.log"
after=$(shasum -a 256 "$crashed" | awk '{print $1}')
test "$before" = "$after"

before_publish="$fixture/before-publish.img"
cp "$image" "$before_publish"
if OPENHDD_TEST_FAIL_BEFORE_PUBLISH=1 \
  "$root/Build/OpenHDDCopyTest" --image "$before_publish" "$source_file" unpublished.bin > "$fixture/before-publish.log" 2>&1; then
  echo 'FAIL: publication interruption reported success' >&2
  exit 1
fi
if "$build/ntfsprogs/ntfscat" -f "$before_publish" /unpublished.bin > "$fixture/unpublished-readback.bin" 2>/dev/null; then
  echo 'FAIL: file published before verification' >&2
  exit 1
fi

after_link="$fixture/after-link.img"
cp "$image" "$after_link"
if OPENHDD_TEST_FAIL_AFTER_LINK=1 \
  "$root/Build/OpenHDDCopyTest" --image "$after_link" "$source_file" linked.bin > "$fixture/after-link.log" 2>&1; then
  echo 'FAIL: publication error reported success' >&2
  exit 1
fi
"$build/ntfsprogs/ntfscat" -f "$after_link" /linked.bin > "$fixture/linked-readback.bin"
cmp "$source_file" "$fixture/linked-readback.bin"
if "$root/Build/OpenHDDCopyTest" --image "$after_link" \
  "$fixture/one.bin" retry-after-link.bin > "$fixture/after-link-retry.log" 2>&1; then
  echo 'FAIL: published but unfinished transfer allowed another write' >&2
  exit 1
fi
grep -q 'Refused: unfinished OpenHDD transfer found' "$fixture/after-link-retry.log"

# Abort at each transaction boundary. A committed copy has no pending name;
# earlier aborts leave a pending name and block another write.
for boundary in 2 3 4 5 0; do
  phase_image="$fixture/abort-$boundary.img"
  cp "$image" "$phase_image"
  before=$(shasum -a 256 "$phase_image" | awk '{print $1}')
  set +e
  OPENHDD_TEST_ABORT_AT_STAGE="$boundary" \
    "$root/Build/OpenHDDCopyTest" --image "$phase_image" \
    "$fixture/boundary-65537.bin" "aborted-$boundary.bin" \
    > "$fixture/abort-$boundary.log" 2>&1
  abort_code=$?
  set -e
  test "$abort_code" -eq 86
  "$build/ntfsprogs/ntfscat" -f "$phase_image" /verified.bin > "$fixture/old-$boundary.bin"
  cmp "$source_file" "$fixture/old-$boundary.bin"
  if [ "$boundary" -eq 2 ]; then
    after=$(shasum -a 256 "$phase_image" | awk '{print $1}')
    test "$before" = "$after"
    continue
  fi
  if [ "$boundary" -eq 5 ] || [ "$boundary" -eq 0 ]; then
    "$build/ntfsprogs/ntfscat" -f "$phase_image" "/aborted-$boundary.bin" \
      > "$fixture/aborted-$boundary-readback.bin"
    cmp "$fixture/boundary-65537.bin" "$fixture/aborted-$boundary-readback.bin"
  elif "$build/ntfsprogs/ntfscat" -f "$phase_image" "/aborted-$boundary.bin" \
    > "$fixture/aborted-$boundary-readback.bin" 2>/dev/null; then
    echo "FAIL: stage $boundary published incomplete file" >&2
    exit 1
  fi
  if [ "$boundary" -ne 0 ]; then
    if "$root/Build/OpenHDDCopyTest" --image "$phase_image" \
      "$fixture/one.bin" "retry-$boundary.bin" \
      > "$fixture/retry-$boundary.log" 2>&1; then
      echo "FAIL: stage $boundary allowed another write" >&2
      exit 1
    fi
    grep -q 'Refused: unfinished OpenHDD transfer found' \
      "$fixture/retry-$boundary.log"
  elif "$build/ntfsprogs/ntfsls" -f -l -a -p / "$phase_image" | \
       grep -q '\.OpenHDD-pending-'; then
    echo 'FAIL: fully committed copy left a temporary name' >&2
    exit 1
  fi
  before=$(shasum -a 256 "$phase_image" | awk '{print $1}')
  "$build/ntfsprogs/ntfsfix" -n "$phase_image" > "$fixture/abort-check-$boundary.log" 2>&1
  after=$(shasum -a 256 "$phase_image" | awk '{print $1}')
  test "$before" = "$after"
done

# Low-level I/O failures at preflight, data write, sync, and final read.
for fault in pread-1 pwrite-8 nospace-8 sync-1 sync-8 sync-14 pread-200 pread-300; do
  kind=${fault%-*}
  number=${fault#*-}
  failed="$fixture/fault-$fault.img"
  cp "$image" "$failed"
  case "$kind" in
    pread) variable=OPENHDD_TEST_FAIL_PREAD_AT ;;
    pwrite) variable=OPENHDD_TEST_FAIL_PWRITE_AT ;;
    nospace) variable=OPENHDD_TEST_ENOSPC_PWRITE_AT ;;
    sync) variable=OPENHDD_TEST_FAIL_SYNC_AT ;;
  esac
  if env "$variable=$number" "$root/Build/OpenHDDCopyTest" \
    --image "$failed" "$source_file" fault.bin > "$fixture/fault-$fault.log" 2>&1; then
    echo "FAIL: $fault reported success" >&2
    exit 1
  fi
  grep -q 'Copy failed' "$fixture/fault-$fault.log"
  "$build/ntfsprogs/ntfscat" -f "$failed" /verified.bin > "$fixture/old-$fault.bin"
  cmp "$source_file" "$fixture/old-$fault.bin"
  if "$build/ntfsprogs/ntfscat" -f "$failed" /fault.bin > "$fixture/new-$fault.bin" 2>/dev/null; then
    cmp "$source_file" "$fixture/new-$fault.bin"
  fi
  before=$(shasum -a 256 "$failed" | awk '{print $1}')
  "$build/ntfsprogs/ntfsfix" -n "$failed" > "$fixture/check-$fault.log" 2>&1
  after=$(shasum -a 256 "$failed" | awk '{print $1}')
  test "$before" = "$after"
done
grep -q 'stage 4' "$fixture/fault-sync-8.log"
grep -q 'stage 6' "$fixture/fault-sync-14.log"
grep -q 'stage 3' "$fixture/fault-pread-200.log"
grep -q 'stage 5' "$fixture/fault-pread-300.log"

# A source larger than the disposable image must never replace older files.
full="$fixture/full.img"
cp "$image" "$full"
mkfile -n 128m "$fixture/too-large.bin"
before=$(shasum -a 256 "$full" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$full" "$fixture/too-large.bin" full.bin > "$fixture/full.log" 2>&1; then
  echo 'FAIL: full image reported success' >&2
  exit 1
fi
grep -q 'Copy failed at stage 1; code 28' "$fixture/full.log"
if "$build/ntfsprogs/ntfscat" -f "$full" /full.bin > "$fixture/full-readback.bin" 2>/dev/null; then
  echo 'FAIL: full image published incomplete file' >&2
  exit 1
fi
"$build/ntfsprogs/ntfscat" -f "$full" /verified.bin > "$fixture/old-full.bin"
cmp "$source_file" "$fixture/old-full.bin"
"$build/ntfsprogs/ntfsfix" -n "$full" > "$fixture/full-check.log" 2>&1
after=$(shasum -a 256 "$full" | awk '{print $1}')
test "$before" = "$after"

not_ntfs="$fixture/not-ntfs.img"
mkfile -n 64m "$not_ntfs"
chmod 600 "$not_ntfs"
before=$(shasum -a 256 "$not_ntfs" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$not_ntfs" "$source_file" denied.bin > "$fixture/non-ntfs.log" 2>&1; then
  echo 'FAIL: non-NTFS image accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$not_ntfs" | awk '{print $1}')
test "$before" = "$after"


# ---------------------------------------------------------------------------
# v1 protocol: dirty mark, several files, Unicode names, folders, duplicates.
# ---------------------------------------------------------------------------
check_state() {
  "$root/Build/OpenHDDCopyTest" --check-image "$1" 2>/dev/null || true
}
cc -std=c11 -O2 -arch arm64 -mmacosx-version-min=15.4 -Wall -Wextra -Werror \
  -I "$root/vendor/ntfs-3g-2026.7.7/include" -I "$root/Build/ntfs3g" \
  "$root/Tests/ntfs_mkdir_fixture.c" \
  "$root/Build/ntfs3g/libntfs-3g/.libs/libntfs-3g.a" \
  -framework CoreFoundation -o "$fixture/mkdir-fixture"

# A committed session leaves the volume clean; every interrupted boundary
# after the dirty mark leaves it dirty, so Windows must check it.
check_state "$image" | grep -q '^dirty=0 .* pending=0 code=0'
for boundary in 3 4 5 6; do
  marked="$fixture/marked-$boundary.img"
  cp "$image" "$marked"
  set +e
  OPENHDD_TEST_ABORT_AT_STAGE="$boundary" "$root/Build/OpenHDDCopyTest" \
    --image "$marked" "$fixture/one.bin" "marked-$boundary.bin" \
    > "$fixture/marked-$boundary.log" 2>&1
  code=$?
  set -e
  test "$code" -eq 86
  check_state "$marked" | grep -q '^dirty=1 '
done
check_state "$fixture/abort-2.img" | grep -q '^dirty=0 '
check_state "$fixture/abort-0.img" | grep -q '^dirty=0 .* pending=0 code=0'
# Stage 6: every file is complete but the mark is still set.
"$build/ntfsprogs/ntfscat" -f "$fixture/marked-6.img" /marked-6.bin > "$fixture/marked-6-readback.bin"
cmp "$fixture/one.bin" "$fixture/marked-6-readback.bin"
check_state "$fixture/marked-6.img" | grep -q 'pending=0'
before=$(shasum -a 256 "$fixture/marked-6.img" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$fixture/marked-6.img" \
  "$fixture/one.bin" after-mark.bin > "$fixture/after-mark.log" 2>&1; then
  echo 'FAIL: write accepted on a volume left dirty by OpenHDD' >&2
  exit 1
fi
grep -q 'dirty volume' "$fixture/after-mark.log"
after=$(shasum -a 256 "$fixture/marked-6.img" | awk '{print $1}')
test "$before" = "$after"

# Several files in one session, Unicode names normalised to NFC.
multi="$fixture/multi.img"
cp "$image" "$multi"
printf 'alpha' > "$fixture/alpha.txt"
dd if=/dev/urandom of="$fixture/beta.bin" bs=1k count=300 status=none
nfd_name=$(printf 'cafe\314\201 \346\227\245\346\234\254.txt')
nfc_name=$(printf 'caf\303\251 \346\227\245\346\234\254.txt')
"$root/Build/OpenHDDCopyTest" --image "$multi" \
  "$fixture/alpha.txt" "Città è bella.txt" \
  "$fixture/beta.bin" "$nfd_name" \
  "$fixture/empty.bin" "vuoto (1).dat" > "$fixture/multi.log"
grep -q 'PASS: 3 file' "$fixture/multi.log"
"$build/ntfsprogs/ntfscat" -f "$multi" "/Città è bella.txt" > "$fixture/multi-a.bin"
cmp "$fixture/alpha.txt" "$fixture/multi-a.bin"
"$build/ntfsprogs/ntfscat" -f "$multi" "/$nfc_name" > "$fixture/multi-b.bin"
cmp "$fixture/beta.bin" "$fixture/multi-b.bin"
"$build/ntfsprogs/ntfscat" -f "$multi" "/vuoto (1).dat" > "$fixture/multi-c.bin"
test ! -s "$fixture/multi-c.bin"
check_state "$multi" | grep -q '^dirty=0 .* pending=0 code=0'

# Names differing only by case are the same name for Windows.
before=$(shasum -a 256 "$multi" | awk '{print $1}')
for request in "VERIFIED.BIN" "CITTÀ È BELLA.TXT"; do
  if "$root/Build/OpenHDDCopyTest" --image "$multi" "$fixture/one.bin" "$request" \
    > "$fixture/case.log" 2>&1; then
    echo "FAIL: case-insensitive duplicate accepted: $request" >&2
    exit 1
  fi
  grep -q 'Copy failed at stage 1; code 17' "$fixture/case.log"
done
if "$root/Build/OpenHDDCopyTest" --image "$multi" "$fixture/one.bin" x.bin \
  "$fixture/alpha.txt" X.BIN > "$fixture/batch-case.log" 2>&1; then
  echo 'FAIL: duplicate names inside one request accepted' >&2
  exit 1
fi
after=$(shasum -a 256 "$multi" | awk '{print $1}')
test "$before" = "$after"

# Names Windows cannot handle are refused before touching the image.
for bad in "CON.txt" "a:b.txt" "trailing " "que?.txt" ".OpenHDD-pending-x" "lpt1"; do
  if "$root/Build/OpenHDDCopyTest" --image "$multi" "$fixture/one.bin" "$bad" \
    > "$fixture/bad.log" 2>&1; then
    echo "FAIL: invalid Windows name accepted: $bad" >&2
    exit 1
  fi
done
after=$(shasum -a 256 "$multi" | awk '{print $1}')
test "$before" = "$after"

# Existing destination folder, including Unicode components.
folders="$fixture/folders.img"
cp "$image" "$folders"
"$fixture/mkdir-fixture" "$folders" "Foto 2026/Viaggi è"
"$root/Build/OpenHDDCopyTest" --image "$folders" --dir "Foto 2026/Viaggi è" \
  "$fixture/beta.bin" "scatto.bin" > "$fixture/folder.log"
"$build/ntfsprogs/ntfscat" -f "$folders" "/Foto 2026/Viaggi è/scatto.bin" > "$fixture/folder-readback.bin"
cmp "$fixture/beta.bin" "$fixture/folder-readback.bin"
if "$build/ntfsprogs/ntfscat" -f "$folders" /scatto.bin > /dev/null 2>&1; then
  echo 'FAIL: file published in the root instead of the folder' >&2
  exit 1
fi
check_state "$folders" | grep -q '^dirty=0 .* pending=0 code=0'
before=$(shasum -a 256 "$folders" | awk '{print $1}')
if "$root/Build/OpenHDDCopyTest" --image "$folders" --dir "Missing" \
  "$fixture/one.bin" x.bin > "$fixture/missing-dir.log" 2>&1; then
  echo 'FAIL: missing destination folder accepted' >&2
  exit 1
fi
grep -q 'destination folder not found' "$fixture/missing-dir.log"
if "$root/Build/OpenHDDCopyTest" --image "$folders" --dir "Foto 2026/../x" \
  "$fixture/one.bin" x.bin > /dev/null 2>&1; then
  echo 'FAIL: parent traversal accepted in destination folder' >&2
  exit 1
fi
after=$(shasum -a 256 "$folders" | awk '{print $1}')
test "$before" = "$after"

# A failure while writing the second file of a batch publishes nothing:
# every file is written and verified before any final name appears. Old
# files stay intact and the volume stays marked for checking.
batch_fail="$fixture/batch-fail.img"
cp "$image" "$batch_fail"
if OPENHDD_TEST_FAIL_AFTER_FIRST_CHUNK=1 "$root/Build/OpenHDDCopyTest" \
  --image "$batch_fail" "$fixture/one.bin" first.bin "$source_file" second.bin \
  > "$fixture/batch-fail.log" 2>&1; then
  echo 'FAIL: batch with a failed file reported success' >&2
  exit 1
fi
grep -q 'item 2 of 2' "$fixture/batch-fail.log"
grep -q 'chkdsk X: /f' "$fixture/batch-fail.log"
if "$build/ntfsprogs/ntfscat" -f "$batch_fail" /first.bin > /dev/null 2>&1; then
  echo 'FAIL: first file published although the batch failed' >&2
  exit 1
fi
"$build/ntfsprogs/ntfscat" -f "$batch_fail" /verified.bin > "$fixture/batch-old.bin"
cmp "$source_file" "$fixture/batch-old.bin"
check_state "$batch_fail" | grep -q '^dirty=1 '
if "$build/ntfsprogs/ntfscat" -f "$batch_fail" /second.bin > /dev/null 2>&1; then
  echo 'FAIL: incomplete second file published' >&2
  exit 1
fi

# Raw devices accept only whole sectors: emulate 4 KiB sectors, where NTFS
# metadata (1 KiB MFT records) needs the read-modify-write layer.
for sector in 512 4096; do
  aligned="$fixture/aligned-$sector.img"
  cp "$image" "$aligned"
  OPENHDD_TEST_ALIGN=$sector "$root/Build/OpenHDDCopyTest" --image "$aligned" \
    "$source_file" "aligned-$sector.bin" "$fixture/one.bin" "tiny-$sector.bin" \
    > "$fixture/aligned-$sector.log" 2>&1
  "$build/ntfsprogs/ntfscat" "$aligned" "/aligned-$sector.bin" > "$fixture/aligned-read.bin"
  cmp "$source_file" "$fixture/aligned-read.bin"
  "$build/ntfsprogs/ntfscat" "$aligned" "/tiny-$sector.bin" > "$fixture/aligned-read.bin"
  cmp "$fixture/one.bin" "$fixture/aligned-read.bin"
  "$build/ntfsprogs/ntfscat" "$aligned" /verified.bin > "$fixture/aligned-old.bin"
  cmp "$source_file" "$fixture/aligned-old.bin"
  check_state "$aligned" | grep -q '^dirty=0 .* pending=0 code=0'
done

# A real change of a source during the copy is refused (nothing published);
# a metadata-only change (xattr, as macOS adds for picked files) is not.
changed="$fixture/changed.img"
cp "$image" "$changed"
cp "$source_file" "$fixture/mutating.bin"
( sleep 0.2; printf 'X' | dd of="$fixture/mutating.bin" bs=1 seek=10 conv=notrunc status=none ) &
if OPENHDD_TEST_ALIGN=512 OPENHDD_TEST_SLOW_WRITE_MS=20 "$root/Build/OpenHDDCopyTest" --image "$changed" \
  "$fixture/mutating.bin" mutating.bin > "$fixture/changed.log" 2>&1; then
  echo 'FAIL: source modified during copy reported success' >&2
  exit 1
fi
wait
grep -q 'changed while it was being copied' "$fixture/changed.log"
if "$build/ntfsprogs/ntfscat" -f "$changed" /mutating.bin > /dev/null 2>&1; then
  echo 'FAIL: modified source was published' >&2
  exit 1
fi
tagged="$fixture/tagged.img"
cp "$image" "$tagged"
cp "$source_file" "$fixture/tagged.bin"
( sleep 0.2; xattr -w com.openhdd.test 1 "$fixture/tagged.bin" ) &
OPENHDD_TEST_SLOW_WRITE_MS=20 "$root/Build/OpenHDDCopyTest" --image "$tagged" \
  "$fixture/tagged.bin" tagged.bin > "$fixture/tagged.log" 2>&1
wait
"$build/ntfsprogs/ntfscat" "$tagged" /tagged.bin > "$fixture/tagged-read.bin"
cmp "$source_file" "$fixture/tagged-read.bin"

# After Windows has checked an interrupted volume (emulated by clearing only
# the dirty flag), OpenHDD removes its own temporaries and copies again.
${build}/ntfsprogs/ntfsfix --help 2>&1 | grep -q -- '--clear-dirty'
for leftover in crashed after-link abort-4 abort-5; do
  repaired="$fixture/repaired-$leftover.img"
  cp "$fixture/$leftover.img" "$repaired"
  check_state "$repaired" | grep -q '^dirty=1 .*pending=1'
  "$build/ntfsprogs/ntfsfix" -d "$repaired" > /dev/null 2>&1
  check_state "$repaired" | grep -q '^dirty=0 .*pending=1'
  "$root/Build/OpenHDDCopyTest" --image "$repaired" "$fixture/one.bin" \
    "after-repair.bin" > "$fixture/repaired-$leftover.log" 2>&1
  grep -q 'Removed 1 OpenHDD temporary' "$fixture/repaired-$leftover.log"
  check_state "$repaired" | grep -q '^dirty=0 .* pending=0 code=0'
  "$build/ntfsprogs/ntfscat" "$repaired" /verified.bin > "$fixture/repaired-old.bin"
  cmp "$source_file" "$fixture/repaired-old.bin"
  "$build/ntfsprogs/ntfscat" "$repaired" /after-repair.bin > "$fixture/repaired-new.bin"
  cmp "$fixture/one.bin" "$fixture/repaired-new.bin"
done
# A published-but-unfinished file keeps its final name after the cleanup.
"$build/ntfsprogs/ntfscat" "$fixture/repaired-after-link.img" /linked.bin > "$fixture/repaired-linked.bin"
cmp "$source_file" "$fixture/repaired-linked.bin"

echo 'PASS: image boundaries, partial I/O, crash phases, faults, disk full, dirty mark, batches, Unicode names and folders; old files intact, no false success'
echo 'Image tests do not validate power loss, physical-drive consistency or Windows chkdsk.'
