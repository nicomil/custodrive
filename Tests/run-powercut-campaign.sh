#!/bin/sh
# Power-cut campaign for the v1 copy protocol, on disposable images only.
#
# For every write index of a reference copy and several seeds, the test build
# holds writes in a volatile cache and, at the cut, persists a random subset
# (some torn at 512-byte boundaries) before dying. Each resulting image is
# classified:
#   untouched  identical to the starting image
#   marked     VOLUME_IS_DIRTY set: Windows must check it (expected after a cut)
#   damaged    marked, but NTFS-3G cannot read the old file before Windows repairs
#   committed  clean, new file complete, no temporary name
#   unreadable NTFS-3G cannot open it (torn metadata record)
#   VIOLATION  clean and changed but not committed: the dirty mark failed
# A clean (committed) image must keep the pre-existing file intact.
#
# Usage: Tests/run-powercut-campaign.sh [PARTITION_IMAGE [EXPORT_DIR [SEEDS]]]
# OPENHDD_CAMPAIGN_EDIT=delete|rename|mkdir cuts a v2 edit instead of a copy
# (on a fresh fixture that also holds the folder Foto/Estate/b.bin).
# PARTITION_IMAGE must already contain /old.bin (defaults to a fresh fixture).
# EXPORT_DIR receives sample images from nine cuts spread over the session.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
if [ ! -x "$build/ntfsprogs/mkntfs" ]; then
  "$root/Tests/run-offline-write-probe.sh" >/dev/null
fi
tool="$root/Build/OpenHDDCopyTest"
ntfscat="$build/ntfsprogs/ntfscat"
work=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-powercut.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
seeds=${3:-4}

base="$work/base.img"
if [ "${1:-}" ]; then
  cp "$1" "$base"
  chmod 600 "$base"
  "$ntfscat" "$base" /old.bin > "$work/old.bin"
else
  mkfile -n 64m "$base"
  chmod 600 "$base"
  "$build/ntfsprogs/mkntfs" -F -Q -L PowerCut "$base" > /dev/null 2>&1
  dd if=/dev/urandom of="$work/old.bin" bs=1k count=700 status=none
  "$tool" --image "$base" "$work/old.bin" old.bin > /dev/null
fi
export_dir=${2:-}
[ -z "$export_dir" ] || mkdir -p "$export_dir"
dd if=/dev/urandom of="$work/new.bin" bs=1k count=2100 status=none
edit=${OPENHDD_CAMPAIGN_EDIT:-}
if [ -n "$edit" ]; then
  "$tool" --image "$base" --mkdir "" Foto > /dev/null
  "$tool" --image "$base" --mkdir Foto Estate > /dev/null
  "$tool" --image "$base" --dir Foto/Estate "$work/new.bin" b.bin > /dev/null
fi
operation() { # image
  case "$edit" in
    delete) "$tool" --image "$1" --delete Foto ;;
    rename) "$tool" --image "$1" --rename Foto "Foto 2026" ;;
    mkdir) "$tool" --image "$1" --mkdir "" Nuova ;;
    *) "$tool" --image "$1" "$work/new.bin" new.bin ;;
  esac
}
committed() { # image: the operation's effect is complete and readable
  case "$edit" in
    delete) ! "$build/ntfsprogs/ntfsls" -p / "$1" 2>/dev/null | grep -q '^Foto$' ;;
    rename) "$ntfscat" "$1" "/Foto 2026/Estate/b.bin" 2>/dev/null | cmp -s - "$work/new.bin" &&
            ! "$build/ntfsprogs/ntfsls" -p / "$1" 2>/dev/null | grep -q '^Foto$' ;;
    mkdir) "$build/ntfsprogs/ntfsls" -p / "$1" 2>/dev/null | grep -q '^Nuova$' ;;
    *) "$ntfscat" "$1" /new.bin > "$work/new-read.bin" 2>/dev/null &&
       cmp -s "$work/new.bin" "$work/new-read.bin" ;;
  esac
}
base_hash=$(shasum -a 256 "$base" | awk '{print $1}')

cp "$base" "$work/count.img"
writes=$(OPENHDD_TEST_POWERCUT_AT_WRITE=999999999 OPENHDD_TEST_REPORT_WRITES=1 \
  operation "$work/count.img" 2>&1 >/dev/null | sed -n 's/^writes=//p')
test -n "$writes"

step=$((writes / 8))
[ "$step" -gt 0 ] || step=1
untouched=0 marked=0 damaged=0 committed=0 unreadable=0 violations=0 runs=0
cut=1
while [ "$cut" -le "$writes" ]; do
  seed=1
  while [ "$seed" -le "$seeds" ]; do
    image="$work/cut.img"
    cp "$base" "$image"
    set +e
    OPENHDD_TEST_POWERCUT_AT_WRITE=$cut OPENHDD_TEST_POWERCUT_SEED=$seed \
      operation "$image" > /dev/null 2>&1
    code=$?
    set -e
    runs=$((runs + 1))
    test "$code" -eq 86
    class=
    if [ "$(shasum -a 256 "$image" | awk '{print $1}')" = "$base_hash" ]; then
      class=untouched
    else
      state=$("$tool" --check-image "$image" 2>/dev/null || true)
      case "$state" in
        *" code=0 "*|*" code=16 "*|*" code=36 "*) ;;
        *) state="unreadable" ;;
      esac
      case "$state" in
        unreadable) class=unreadable ;;
        dirty=1*) class=marked ;;
        dirty=0*)
          if printf '%s' "$state" | grep -q 'pending=0 code=0' && committed "$image"; then
            class=committed
          else
            class=VIOLATION
          fi ;;
        *) class=unreadable ;;
      esac
    fi
    if [ "$class" = marked ] || [ "$class" = committed ]; then
      if ! "$ntfscat" -f "$image" /old.bin > "$work/old-read.bin" 2>/dev/null ||
         ! cmp -s "$work/old.bin" "$work/old-read.bin"; then
        if [ "$class" = committed ]; then
          echo "FAIL: clean volume with damaged old file at cut $cut seed $seed" >&2
          exit 1
        fi
        class=damaged
      fi
    fi
    case "$class" in
      untouched) untouched=$((untouched + 1)) ;;
      marked) marked=$((marked + 1)) ;;
      damaged) damaged=$((damaged + 1)) ;;
      committed) committed=$((committed + 1)) ;;
      unreadable) unreadable=$((unreadable + 1)) ;;
      VIOLATION) violations=$((violations + 1))
        echo "VIOLATION at cut $cut seed $seed: $state" >&2 ;;
    esac
    # Samples for Windows: seed 1 at nine cuts spread over the whole session.
    if [ -n "$export_dir" ] && [ "$class" != untouched ] && [ "$seed" -eq 1 ] &&
       { [ $(( (cut - 2) % step )) -eq 0 ] || [ "$cut" -eq "$writes" ]; }; then
      cp "$image" "$export_dir/$class-s${OPENHDD_TEST_POWERCUT_SECTOR:-512}-cut$cut.img"
    fi
    seed=$((seed + 1))
  done
  cut=$((cut + 1))
done

printf 'sector=%s writes=%s runs=%s untouched=%s marked=%s damaged=%s committed=%s unreadable=%s violations=%s\n' \
  "${OPENHDD_TEST_POWERCUT_SECTOR:-512}" "$writes" "$runs" "$untouched" "$marked" "$damaged" "$committed" "$unreadable" "$violations"
test "$violations" -eq 0
echo 'PASS: every cut left the volume untouched, marked for checking or committed; old file intact'
echo 'Windows must still confirm that chkdsk /f repairs the marked images.'
