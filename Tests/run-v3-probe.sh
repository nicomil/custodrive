#!/bin/sh
# v3 on disposable NTFS images only: folder copies from a manifest, batches,
# replacing existing files (with the recovery journal) and moving entries.
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
fixture=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-v3.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM

fail() { echo "FAIL: $*" >&2; exit 1; }
state() { "$tool" --check-image "$1" 2>/dev/null || true; }
clean() { state "$1" | grep -q '^dirty=0 .* pending=0 code=0' || fail "$2: volume not clean"; }
hash() { shasum -a 256 "$1" | awk '{print $1}'; }
same() { "$cat_tool" -f "$1" "$2" 2>/dev/null | cmp -s - "$3" || fail "$4: $2 differs"; }
tree() { "$ls_tool" -f -R -p / "$1" 2>/dev/null; }
exists() { "$cat_tool" -f "$1" "$2" > /dev/null 2>&1; }
record() { for field in "$@"; do printf '%s\0' "$field"; done; }
random() { dd if=/dev/urandom of="$1" bs=1k count="$2" status=none; }
no_leftovers() { tree "$1" | grep -q 'OpenHDD' && fail "$2: OpenHDD entries left" || true; }

base="$fixture/base.img"
mkfile -n 160m "$base"
chmod 600 "$base"
"$build/ntfsprogs/mkntfs" -F -Q -L V3Probe "$base" > /dev/null 2>&1
random "$fixture/keep.bin" 700
random "$fixture/x.bin" 90
random "$fixture/case.bin" 30
"$tool" --image "$base" "$fixture/keep.bin" keep.bin "$fixture/case.bin" Case.bin > /dev/null
"$tool" --image "$base" --mkdir "" Esistente > /dev/null
"$tool" --image "$base" --dir Esistente "$fixture/x.bin" x.bin > /dev/null
clean "$base" base
fresh() { cp "$base" "$fixture/$1.img"; echo "$fixture/$1.img"; }
keep_intact() { same "$1" /keep.bin "$fixture/keep.bin" "$2"; }

# Folder copy: nested folders, accents, an empty folder, a merge into an
# existing folder.
src="$fixture/src"
mkdir -p "$src/Giorno 1" "$src/Vuota"
random "$src/a.bin" 300
random "$src/Giorno 1/b.bin" 1200
random "$src/Giorno 1/c è.bin" 5
: > "$src/zero.bin"
{
  record D Vacanze D "Vacanze/Giorno 1" D Vacanze/Vuota D Esistente
  record F "$src/a.bin" Vacanze a.bin 0
  record F "$src/Giorno 1/b.bin" "Vacanze/Giorno 1" b.bin 0
  record F "$src/Giorno 1/c è.bin" "Vacanze/Giorno 1" "c è.bin" 0
  record F "$src/zero.bin" Vacanze zero.bin 0
  record F "$src/a.bin" Esistente nuovo.bin 0
} > "$fixture/tree.manifest"
img=$(fresh tree)
"$tool" --image "$img" --manifest "$fixture/tree.manifest" > "$fixture/out.log" 2>&1 ||
  { cat "$fixture/out.log" >&2; fail "folder copy refused"; }
grep -q 'PASS: 5 file(s) and 4 folder(s) copied' "$fixture/out.log" || fail "folder copy summary"
same "$img" /Vacanze/a.bin "$src/a.bin" tree
same "$img" "/Vacanze/Giorno 1/b.bin" "$src/Giorno 1/b.bin" tree
same "$img" "/Vacanze/Giorno 1/c è.bin" "$src/Giorno 1/c è.bin" tree
same "$img" /Vacanze/zero.bin "$src/zero.bin" tree
same "$img" /Esistente/nuovo.bin "$src/a.bin" tree
same "$img" /Esistente/x.bin "$fixture/x.bin" tree
tree "$img" | grep -q '^Vuota$' || fail "empty folder missing"
keep_intact "$img" tree
clean "$img" tree
no_leftovers "$img" tree

# Folder copy refusals leave the image unchanged: clash with an existing
# file, two names differing only in case, a file where a folder should go.
img=$(fresh tree-refuse)
before=$(hash "$img")
for manifest in clash dup filefolder parent; do
  case "$manifest" in
    clash) record F "$src/a.bin" Esistente X.BIN 0 ;;
    dup) record D Nuova F "$src/a.bin" Nuova a.bin 0 F "$src/a.bin" Nuova A.bin 0 ;;
    filefolder) record D keep.bin/sotto ;;
    parent) record D Manca/sotto ;;
  esac > "$fixture/$manifest.manifest"
  if "$tool" --image "$img" --manifest "$fixture/$manifest.manifest" > /dev/null 2>&1; then
    fail "accepted manifest $manifest"
  fi
done
[ "$(hash "$img")" = "$before" ] || fail "a refused folder copy changed the image"

# Batches: 25 files in batches of 4, one progress line for the whole copy.
mkdir -p "$fixture/many"
: > "$fixture/many.manifest"
record D Molti >> "$fixture/many.manifest"
n=1
while [ "$n" -le 25 ]; do
  random "$fixture/many/f$n.bin" $((n * 7))
  record F "$fixture/many/f$n.bin" Molti "f$n.bin" 0 >> "$fixture/many.manifest"
  n=$((n + 1))
done
img=$(fresh batches)
: > "$fixture/progress"
OPENHDD_TEST_BATCH_FILES=4 "$tool" --image "$img" --progress "$fixture/progress" \
  --manifest "$fixture/many.manifest" > /dev/null || fail "batched copy"
read -r phase index count done total < "$fixture/progress"
[ "$phase" = 5 ] && [ "$index" = 24 ] && [ "$count" = 25 ] && [ "$done" = "$total" ] ||
  fail "batched progress ended at: $phase $index $count $done $total"
n=1
while [ "$n" -le 25 ]; do same "$img" "/Molti/f$n.bin" "$fixture/many/f$n.bin" batches; n=$((n + 1)); done
clean "$img" batches
# A clash in the second batch refuses that batch only; the first stays.
img=$(fresh batch-fail)
cp "$fixture/many.manifest" "$fixture/fail.manifest"
record F "$fixture/many/f1.bin" Esistente x.bin 0 >> "$fixture/fail.manifest"
set +e
OPENHDD_TEST_BATCH_FILES=13 "$tool" --image "$img" --manifest "$fixture/fail.manifest" \
  > "$fixture/out.log" 2>&1
code=$?
set -e
[ "$code" -ne 0 ] || fail "clash in last batch accepted"
grep -q 'Earlier batches: 13 file(s)' "$fixture/out.log" || { cat "$fixture/out.log"; fail "batch failure message"; }
same "$img" /Molti/f13.bin "$fixture/many/f13.bin" batch-fail
exists "$img" /Molti/f14.bin && fail "refused batch left a file"
clean "$img" batch-fail

# Many small files in one batch: every temporary name goes into the root,
# whose index outgrows the index root after about fifteen entries.
mkdir -p "$fixture/small"
: > "$fixture/small.manifest"
record D Piccoli >> "$fixture/small.manifest"
n=1
while [ "$n" -le 300 ]; do
  head -c $((n * 13)) /dev/urandom > "$fixture/small/s$n.jpg"
  record F "$fixture/small/s$n.jpg" Piccoli "s$n.jpg" 0 >> "$fixture/small.manifest"
  n=$((n + 1))
done
img=$(fresh small)
"$tool" --image "$img" --manifest "$fixture/small.manifest" > "$fixture/out.log" 2>&1 ||
  { cat "$fixture/out.log" >&2; fail "300 small files in one batch"; }
for n in 1 15 16 17 150 300; do same "$img" "/Piccoli/s$n.jpg" "$fixture/small/s$n.jpg" small; done
clean "$img" small

# Replace: a single file, a file inside a folder via the manifest.
random "$fixture/new-keep.bin" 1500
img=$(fresh replace)
"$tool" --image "$img" --replace "$fixture/new-keep.bin" keep.bin > /dev/null || fail "replace"
same "$img" /keep.bin "$fixture/new-keep.bin" replace
record F "$fixture/case.bin" Esistente x.bin 1 F "$fixture/case.bin" Esistente y.bin 1 \
  > "$fixture/replace.manifest"
"$tool" --image "$img" --manifest "$fixture/replace.manifest" > /dev/null || fail "manifest replace"
same "$img" /Esistente/x.bin "$fixture/case.bin" replace
same "$img" /Esistente/y.bin "$fixture/case.bin" replace
clean "$img" replace
no_leftovers "$img" replace
# Refusals: no --replace, a different letter case, a folder as target.
img=$(fresh replace-refuse)
before=$(hash "$img")
for request in "keep.bin" "--replace case.bin" "--replace Esistente"; do
  set -- $request
  name=${2:-$1}
  flag=
  [ $# -eq 2 ] && flag=--replace
  if "$tool" --image "$img" $flag "$fixture/x.bin" "$name" > /dev/null 2>&1; then
    fail "accepted replace: $request"
  fi
done
[ "$(hash "$img")" = "$before" ] || fail "a refused replace changed the image"

# Interrupted replace, then Windows repair (emulated by ntfsfix) and the
# next OpenHDD session: the name holds the old file or the new one, never
# neither, and the journal and temporaries are gone.
recover() { # image expected-file label
  state "$1" | grep -q '^dirty=1 ' || fail "$3: not marked dirty"
  "$build/ntfsprogs/ntfsfix" -d "$1" > /dev/null 2>&1
  "$tool" --image "$1" --mkdir "" dopo > "$fixture/recover.log" 2>&1 ||
    { cat "$fixture/recover.log" >&2; fail "$3: recovery session refused"; }
  grep -q 'Removed' "$fixture/recover.log" || fail "$3: nothing recovered"
  same "$1" /keep.bin "$2" "$3"
  clean "$1" "$3"
  no_leftovers "$1" "$3"
}
for point in stage3 stage4 aside stage5 stage6; do
  img=$(fresh "replace-$point")
  set +e
  case "$point" in
    aside) OPENHDD_TEST_ABORT_AFTER_ASIDE=1 "$tool" --image "$img" --replace \
             "$fixture/new-keep.bin" keep.bin > /dev/null 2>&1 ;;
    *) OPENHDD_TEST_ABORT_AT_STAGE=${point#stage} "$tool" --image "$img" --replace \
         "$fixture/new-keep.bin" keep.bin > /dev/null 2>&1 ;;
  esac
  code=$?
  set -e
  [ "$code" -eq 86 ] || fail "replace abort $point exit $code"
  case "$point" in
    stage3|stage4|aside) recover "$img" "$fixture/keep.bin" "replace-$point" ;;
    stage5) recover "$img" "$fixture/new-keep.bin" "replace-$point" ;;
    stage6) state "$img" | grep -q '^dirty=1 ' || fail "stage 6 not dirty"
            same "$img" /keep.bin "$fixture/new-keep.bin" "replace-$point" ;;
  esac
done

# Move: a file, a folder with content, back to the root.
img=$(fresh move)
"$tool" --image "$img" --mkdir "" Archivio > /dev/null
"$tool" --image "$img" --move Archivio keep.bin > /dev/null || fail "move file"
same "$img" /Archivio/keep.bin "$fixture/keep.bin" move
exists "$img" /keep.bin && fail "moved file still in the root"
"$tool" --image "$img" --move Archivio Esistente > /dev/null || fail "move folder"
same "$img" /Archivio/Esistente/x.bin "$fixture/x.bin" move
"$tool" --image "$img" --move "" Archivio/keep.bin Archivio/Esistente > /dev/null || fail "move to root"
same "$img" /keep.bin "$fixture/keep.bin" move
same "$img" /Esistente/x.bin "$fixture/x.bin" move
clean "$img" move
# Refusals leave the image unchanged.
img=$(fresh move-refuse)
"$tool" --image "$img" --mkdir Esistente Sotto > /dev/null
"$tool" --image "$img" --dir "" "$fixture/x.bin" X.bin > /dev/null
before=$(hash "$img")
for request in "Esistente Esistente" "Esistente/Sotto Esistente" "'' keep.bin" \
  "Esistente X.bin" "Esistente '\$MFT'" "Manca keep.bin" "keep.bin Case.bin" \
  "Esistente/Sotto Esistente/x.bin Esistente"; do
  if eval "\"$tool\" --image \"$img\" --move $request" > /dev/null 2>&1; then
    fail "accepted move: $request"
  fi
done
[ "$(hash "$img")" = "$before" ] || fail "a refused move changed the image"
img=$(fresh move-abort)
set +e
OPENHDD_TEST_ABORT_AT_STAGE=3 "$tool" --image "$img" --move Esistente keep.bin > /dev/null 2>&1
set -e
state "$img" | grep -q '^dirty=1 ' || fail "interrupted move not marked dirty"

# Cancel (SIGINT) while a batch is written: the batch is undone, new
# folders removed, earlier batches kept, the volume clean.
mkdir -p "$fixture/big"
: > "$fixture/cancel.manifest"
record D Annullata D Annullata/Sotto >> "$fixture/cancel.manifest"
n=1
while [ "$n" -le 9 ]; do
  random "$fixture/big/b$n.bin" 3000
  record F "$fixture/big/b$n.bin" Annullata/Sotto "b$n.bin" 0 >> "$fixture/cancel.manifest"
  n=$((n + 1))
done
cancel_copy() { # image batch-size delay
  OPENHDD_TEST_BATCH_FILES=$2 OPENHDD_TEST_SLOW_WRITE_MS=30 \
    "$tool" --image "$1" --manifest "$fixture/cancel.manifest" > "$fixture/cancel.log" 2>&1 &
  pid=$!
  sleep "$3"
  kill -INT "$pid" 2>/dev/null || true
  set +e
  wait "$pid"
  code=$?
  set -e
  [ "$code" -ne 0 ] || fail "cancelled copy reported success (too fast?)"
  grep -q 'Cancelled:' "$fixture/cancel.log" || { cat "$fixture/cancel.log" >&2; fail "no cancel message"; }
  clean "$1" cancel
  no_leftovers "$1" cancel
  keep_intact "$1" cancel
}
img=$(fresh cancel-one)
cancel_copy "$img" 1000 2
tree "$img" | grep -q '^Annullata$' && fail "cancelled batch left its new folder"
img=$(fresh cancel-batches)
cancel_copy "$img" 3 5
grep -q 'Earlier batches: [1-9]' "$fixture/cancel.log" || fail "no batch kept before the cancel"
same "$img" /Annullata/Sotto/b1.bin "$fixture/big/b1.bin" cancel
exists "$img" /Annullata/Sotto/b9.bin && fail "cancel copied everything"

# A move or rename cut while the entry has both names: after the repair the
# next session removes the old name (or, for a change of case, keeps one).
two_names() { # label expect-present expect-absent -- tool arguments
  label=$1 present=$2 absent=$3; shift 4
  img=$(fresh "two-$label")
  "$tool" --image "$img" --mkdir "" Archivio > /dev/null
  set +e
  OPENHDD_TEST_ABORT_WITH_TWO_NAMES=1 "$tool" --image "$img" "$@" > /dev/null 2>&1
  code=$?
  set -e
  [ "$code" -eq 86 ] || fail "$label: abort exit $code"
  state "$img" | grep -q '^dirty=1 ' || fail "$label: not marked dirty"
  "$build/ntfsprogs/ntfsfix" -d "$img" > /dev/null 2>&1
  "$tool" --image "$img" --mkdir "" dopo > "$fixture/two.log" 2>&1 ||
    { cat "$fixture/two.log" >&2; fail "$label: recovery session refused"; }
  exists "$img" "$present" || fail "$label: $present missing after recovery"
  [ -z "$absent" ] || ! tree "$img" | grep -qx "$(basename "$absent")" ||
    ! exists "$img" "$absent" || fail "$label: $absent still present"
  clean "$img" "$label"
  no_leftovers "$img" "$label"
}
two_names move-file /Archivio/keep.bin /keep.bin -- --move Archivio keep.bin
same "$img" /Archivio/keep.bin "$fixture/keep.bin" move-file
two_names move-folder /Archivio/Esistente/x.bin /Esistente/x.bin -- --move Archivio Esistente
two_names rename /nuovo.bin /keep.bin -- --rename keep.bin nuovo.bin
same "$img" /nuovo.bin "$fixture/keep.bin" rename
two_names case /Case.bin "" -- --rename Case.bin CASE.bin
tree "$img" | grep -qx 'Case.bin' || fail "case: original name not kept"

echo 'PASS: folder copies (nested, empty, merged), 300 small files in one batch, refusals unchanged, batches with one progress bar, replace with journal recovery at every interruption point, moves of files and folders, move and rename recovery from the journal, cancel undoing the batch in progress'
