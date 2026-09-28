#!/bin/sh
# v2 edits (delete, rename, new folder) on disposable NTFS images only.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
if [ ! -x "$build/ntfsprogs/mkntfs" ]; then
  "$root/Tests/run-offline-write-probe.sh" >/dev/null
fi
tool="$root/Build/OpenHDDCopyTest"
cat_tool="$build/ntfsprogs/ntfscat"
ls_tool="$build/ntfsprogs/ntfsls"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-edit.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
state() { "$tool" --check-image "$1" 2>/dev/null || true; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
tree() { "$ls_tool" -f -R -p / "$1" 2>/dev/null; }
exists() { "$cat_tool" -f "$1" "$2" > /dev/null 2>&1; }

# Base volume: a file that must never change, plus a small tree.
base="$fixture/base.img"
mkfile -n 128m "$base"
chmod 600 "$base"
"$build/ntfsprogs/mkntfs" -F -Q -L EditProbe "$base" > /dev/null 2>&1
dd if=/dev/urandom of="$fixture/keep.bin" bs=1k count=700 status=none
for n in 1 2 3 4; do dd if=/dev/urandom of="$fixture/f$n.bin" bs=1k count=200 status=none; done
"$tool" --image "$base" "$fixture/keep.bin" "keep.bin" "$fixture/f1.bin" "uno.bin" \
  "$fixture/f2.bin" "Città.txt" > /dev/null
"$tool" --image "$base" --mkdir "" "Foto" > /dev/null
"$tool" --image "$base" --mkdir "Foto" "Estate è" > /dev/null
"$tool" --image "$base" --dir "Foto" "$fixture/f3.bin" "a.bin" > /dev/null
"$tool" --image "$base" --dir "Foto/Estate è" "$fixture/f4.bin" "b.bin" > /dev/null
state "$base" | grep -q '^dirty=0 .* pending=0 code=0' || fail "base not clean"

keep_intact() {
  "$cat_tool" -f "$1" /keep.bin > "$fixture/keep-read.bin" || fail "keep.bin unreadable in $1"
  cmp -s "$fixture/keep.bin" "$fixture/keep-read.bin" || fail "keep.bin changed in $1"
}
fresh() { cp "$base" "$fixture/$1.img"; echo "$fixture/$1.img"; }

# Delete: a file, several files at once, a whole tree.
img=$(fresh delete)
"$tool" --image "$img" --delete "uno.bin" > /dev/null
exists "$img" /uno.bin && fail "deleted file still present"
"$tool" --image "$img" --delete "Città.txt" "Foto/a.bin" > /dev/null
exists "$img" "/Città.txt" && fail "second deleted file still present"
exists "$img" /Foto/a.bin && fail "file in folder still present"
"$tool" --image "$img" --delete "Foto" > /dev/null
tree "$img" | grep -q Foto && fail "deleted tree still listed"
keep_intact "$img"
state "$img" | grep -q '^dirty=0 .* pending=0 code=0' || fail "delete left volume unclean"

# Rename: file, folder with content, change of letter case only.
img=$(fresh rename)
"$tool" --image "$img" --rename "uno.bin" "primo file.bin" > /dev/null
"$cat_tool" "$img" "/primo file.bin" | cmp -s - "$fixture/f1.bin" || fail "renamed file content"
exists "$img" /uno.bin && fail "old name still present"
"$tool" --image "$img" --rename "Foto" "Foto 2026" > /dev/null
"$cat_tool" "$img" "/Foto 2026/Estate è/b.bin" | cmp -s - "$fixture/f4.bin" || fail "renamed folder content"
"$tool" --image "$img" --rename "Foto 2026/a.bin" "A.bin" > /dev/null
"$cat_tool" "$img" "/Foto 2026/A.bin" | cmp -s - "$fixture/f3.bin" || fail "case-only rename"
tree "$img" | grep -q '^a\.bin$' && fail "case-only rename left the old name"
tree "$img" | grep -q 'OpenHDD' && fail "rename left a temporary name"
keep_intact "$img"
state "$img" | grep -q '^dirty=0 .* pending=0 code=0' || fail "rename left volume unclean"

# New folder: in the root and nested, then a copy into it.
img=$(fresh mkdir)
"$tool" --image "$img" --mkdir "" "Nuova cartella" > /dev/null
"$tool" --image "$img" --mkdir "Nuova cartella" "Più dentro" > /dev/null
"$tool" --image "$img" --dir "Nuova cartella/Più dentro" "$fixture/f1.bin" "x.bin" > /dev/null
"$cat_tool" "$img" "/Nuova cartella/Più dentro/x.bin" | cmp -s - "$fixture/f1.bin" || fail "copy into new folder"
keep_intact "$img"

# Refusals leave the image byte-for-byte unchanged.
img=$(fresh refuse)
before=$(hash "$img")
for request in \
  "--delete '\$MFT'" "--delete 'System Volume Information'" "--delete missing.bin" \
  "--delete Foto/../keep.bin" "--rename keep.bin UNO.BIN" "--rename keep.bin a:b" \
  "--rename missing.bin x.bin" "--rename keep.bin keep.bin" "--mkdir '' Foto" \
  "--mkdir '' FOTO" "--mkdir Missing x" "--mkdir '' CON" "--delete .OpenHDD-x"; do
  if eval "\"$tool\" --image \"$img\" $request" > "$fixture/refuse.log" 2>&1; then
    fail "accepted: $request"
  fi
done
[ "$(hash "$img")" = "$before" ] || fail "a refused edit changed the image"

# A junction/symlink is never followed: NTFS-3G's fixture tools cannot create
# reparse points, so this is covered by the engine refusing item.special.

# Interruptions: stage 2 before any write keeps the image; later ones leave
# the volume marked dirty, and a repaired volume accepts edits again.
for boundary in 2 3 6; do
  img=$(fresh "abort-$boundary")
  before=$(hash "$img")
  set +e
  OPENHDD_TEST_ABORT_AT_STAGE=$boundary "$tool" --image "$img" --delete "Foto" > /dev/null 2>&1
  code=$?
  set -e
  [ "$code" -eq 86 ] || fail "abort $boundary exit $code"
  keep_intact "$img"
  if [ "$boundary" -eq 2 ]; then
    [ "$(hash "$img")" = "$before" ] || fail "stage 2 abort changed the image"
    continue
  fi
  state "$img" | grep -q '^dirty=1 ' || fail "abort $boundary not marked dirty"
  if "$tool" --image "$img" --mkdir "" "dopo" > /dev/null 2>&1; then
    fail "edit accepted on a volume left dirty"
  fi
  "$build/ntfsprogs/ntfsfix" -d "$img" > /dev/null 2>&1
  "$tool" --image "$img" --mkdir "" "dopo" > /dev/null || fail "edit refused after repair"
  keep_intact "$img"
done
img=$(fresh abort-first-edit)
set +e
OPENHDD_TEST_ABORT_AFTER_FIRST_EDIT=1 "$tool" --image "$img" --delete "uno.bin" "Città.txt" > /dev/null 2>&1
set -e
state "$img" | grep -q '^dirty=1 ' || fail "mid-batch abort not marked dirty"
keep_intact "$img"

# Faults at write and sync never report success.
for fault in pwrite-3 sync-2 sync-5; do
  img=$(fresh "fault-$fault")
  case "${fault%-*}" in
    pwrite) variable=OPENHDD_TEST_FAIL_PWRITE_AT ;;
    sync) variable=OPENHDD_TEST_FAIL_SYNC_AT ;;
  esac
  if env "$variable=${fault#*-}" "$tool" --image "$img" --rename "Foto" "Altro" > "$fixture/fault.log" 2>&1; then
    fail "$fault reported success"
  fi
  grep -q 'Copy failed' "$fixture/fault.log" || fail "$fault without failure message"
  keep_intact "$img"
done

echo 'PASS: delete (files, batches, trees), rename (file, folder, case only), new folder, refusals unchanged, dirty mark on interruption, repair and faults; untouched file intact'
