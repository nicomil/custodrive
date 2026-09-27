#!/bin/sh
# Tests the fd-bound copy engine on disposable regular-file images only.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
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
dd if=/dev/urandom of="$source_file" bs=1m count=8 status=none
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
grep -q 'invalid new file name. No disk access' "$fixture/invalid-name.log"
after=$(shasum -a 256 "$image" | awk '{print $1}')
test "$before" = "$after"
"$root/Build/OpenHDDCopyTest" --image "$image" "$source_file" verified.bin
"$build/ntfsprogs/ntfscat" "$image" /verified.bin > "$fixture/readback.bin"
cmp "$source_file" "$fixture/readback.bin"

touch "$fixture/empty.bin"
"$root/Build/OpenHDDCopyTest" --image "$image" "$fixture/empty.bin" empty.bin
"$build/ntfsprogs/ntfscat" "$image" /empty.bin > "$fixture/empty-readback.bin"
test ! -s "$fixture/empty-readback.bin"

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
if "$build/ntfsprogs/ntfscat" "$interrupted" /partial.bin > "$fixture/partial-readback.bin" 2>/dev/null; then
  echo 'FAIL: incomplete file published at final name' >&2
  exit 1
fi

# A process exit skips inode close, unmount and sync; this is not a power-cut test.
make -C "$build/ntfsprogs" ntfsls >/dev/null
crashed="$fixture/crashed.img"
"$build/ntfsprogs/ntfsls" -l -a -p / "$image" | \
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
"$build/ntfsprogs/ntfsls" -l -a -p / "$crashed" | \
  awk '/\.OpenHDD-pending-/ {print $NF}' | sort > "$fixture/pending-after.txt"
pending=$(comm -13 "$fixture/pending-before.txt" "$fixture/pending-after.txt")
test -n "$pending"
test "$(printf '%s\n' "$pending" | wc -l | tr -d ' ')" -eq 1
"$build/ntfsprogs/ntfscat" "$crashed" "/$pending" > "$fixture/crash-pending.bin"
cmp -n 65536 "$source_file" "$fixture/crash-pending.bin"
if cmp -s "$source_file" "$fixture/crash-pending.bin"; then
  echo 'FAIL: crash probe did not interrupt the copy' >&2
  exit 1
fi
if "$build/ntfsprogs/ntfscat" "$crashed" /crashed.bin > "$fixture/crash-final.bin" 2>/dev/null; then
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
if "$build/ntfsprogs/ntfscat" "$before_publish" /unpublished.bin > "$fixture/unpublished-readback.bin" 2>/dev/null; then
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
"$build/ntfsprogs/ntfscat" "$after_link" /linked.bin > "$fixture/linked-readback.bin"
cmp "$source_file" "$fixture/linked-readback.bin"

# Low-level I/O failures at preflight, data write, sync, and final read.
for fault in pread-1 pwrite-100 nospace-100 sync-1 sync-5 pread-500; do
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
  "$build/ntfsprogs/ntfscat" "$failed" /verified.bin > "$fixture/old-$fault.bin"
  cmp "$source_file" "$fixture/old-$fault.bin"
  if "$build/ntfsprogs/ntfscat" "$failed" /fault.bin > "$fixture/new-$fault.bin" 2>/dev/null; then
    cmp "$source_file" "$fixture/new-$fault.bin"
  fi
  before=$(shasum -a 256 "$failed" | awk '{print $1}')
  "$build/ntfsprogs/ntfsfix" -n "$failed" > "$fixture/check-$fault.log" 2>&1
  after=$(shasum -a 256 "$failed" | awk '{print $1}')
  test "$before" = "$after"
done
grep -q 'stage 4' "$fixture/fault-sync-5.log"
grep -q 'stage 5' "$fixture/fault-pread-500.log"

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
if "$build/ntfsprogs/ntfscat" "$full" /full.bin > "$fixture/full-readback.bin" 2>/dev/null; then
  echo 'FAIL: full image published incomplete file' >&2
  exit 1
fi
"$build/ntfsprogs/ntfscat" "$full" /verified.bin > "$fixture/old-full.bin"
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

echo 'PASS: image copy, crash, I/O faults and disk full; old files intact, no false success'
echo 'Image tests do not validate power loss, physical-drive consistency or Windows chkdsk.'
