#!/bin/sh
# Builds the Windows verification set for v3: folder copies (with a merge
# into a folder Windows created), replacing files Windows created, moving a
# Windows folder and file, interruptions at the delicate points and
# power-cut samples. Every case lists where each file must be afterwards;
# "found:" only asks that the content survives somewhere (an interrupted
# replacement keeps the old file aside until the Mac settles the journal).
#
# Usage: Tests/prepare-windows-v3-cases.sh BASE.vhd BASE-files.sha256 OUT_DIR
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base_vhd=$1
base_list=$2
out=$3
tool="$root/Build/OpenHDDCopyTest"
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-v3w.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

geometry=$(python3 - "$base_vhd" <<'PY'
import struct, sys
data = open(sys.argv[1], 'rb')
data.seek(-512, 2)
footer = data.read(512)
assert footer[:8] == b'conectix' and struct.unpack('>I', footer[60:64])[0] == 2
data.seek(0)
mbr = data.read(512)
parts = [mbr[446 + 16 * i:462 + 16 * i] for i in range(4)]
parts = [p for p in parts if p[4]]
assert len(parts) == 1 and parts[0][4] == 7
print(*struct.unpack('<II', parts[0][8:16]))
PY
)
lba=${geometry% *}
sectors=${geometry#* }
partition="$work/base.img"
dd if="$base_vhd" of="$partition" bs=512 skip="$lba" count="$sectors" status=none
chmod 600 "$partition"
wrap() { cp "$base_vhd" "$out/$2.vhd"; dd if="$1" of="$out/$2.vhd" bs=512 seek="$lba" conv=notrunc status=none; }
h() { shasum -a 256 "$1" | awk '{print $1}'; }
listed() { # hash of a file in the Windows list (UTF-8 with BOM, CRLF)
  python3 - "$base_list" "$1" <<'PY'
import sys
for line in open(sys.argv[1], encoding='utf-8-sig'):
    parts = line.strip().split('  ', 2)
    if len(parts) == 3 and parts[2].strip() == sys.argv[2]:
        print(parts[0].strip().lower())
PY
}
record() { for field in "$@"; do printf '%s\0' "$field"; done; }
case_line() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$out/cases.tsv"; }

# Files Windows created: they are checked per case, at their expected place.
O=$(listed old.bin); G=$(listed 'Documenti\grande.bin'); N=$(listed 'Documenti\nota.txt')
[ -n "$O" ] && [ -n "$G" ] && [ -n "$N" ]
windows="$O|old.bin;$G|Documenti\\grande.bin;$N|Documenti\\nota.txt"
: > "$out/base-files.sha256"
printf 'case\texpect\tnew_files\n' > "$out/cases.tsv"

dd if=/dev/urandom of="$work/a.bin" bs=1k count=800 status=none
dd if=/dev/urandom of="$work/b.bin" bs=1k count=150 status=none
dd if=/dev/urandom of="$work/c.bin" bs=1k count=40 status=none
dd if=/dev/urandom of="$work/r.bin" bs=1k count=900 status=none
printf 'nota sostituita da OpenHDD\r\n' > "$work/m.txt"
A=$(h "$work/a.bin"); B=$(h "$work/b.bin"); C=$(h "$work/c.bin"); R=$(h "$work/r.bin"); M=$(h "$work/m.txt")
{
  record D Album D "Album/Giorno è" D Album/Vuota D Documenti
  record F "$work/a.bin" Album a.bin 0 F "$work/b.bin" "Album/Giorno è" b.bin 0
  record F "$work/c.bin" Documenti nuovo.bin 0
} > "$work/tree.manifest"
record F "$work/m.txt" Documenti nota.txt 1 > "$work/nota.manifest"

wrap "$partition" v3-prepared
case_line v3-prepared clean "$windows"

img="$work/tree.img"; cp "$partition" "$img"
"$tool" --image "$img" --manifest "$work/tree.manifest" > /dev/null
wrap "$img" v3-committed-tree
case_line v3-committed-tree clean "$windows;$A|Album\\a.bin;$B|Album\\Giorno è\\b.bin;$C|Documenti\\nuovo.bin;dir:Album\\Vuota"

img="$work/replace.img"; cp "$partition" "$img"
"$tool" --image "$img" --replace "$work/r.bin" old.bin > /dev/null
"$tool" --image "$img" --manifest "$work/nota.manifest" > /dev/null
wrap "$img" v3-committed-replace
case_line v3-committed-replace clean "$R|old.bin;$G|Documenti\\grande.bin;$M|Documenti\\nota.txt"

img="$work/move.img"; cp "$partition" "$img"
"$tool" --image "$img" --mkdir "" Archivio > /dev/null
"$tool" --image "$img" --move Archivio Documenti old.bin > /dev/null
wrap "$img" v3-committed-move
case_line v3-committed-move clean "$O|Archivio\\old.bin;$G|Archivio\\Documenti\\grande.bin;$N|Archivio\\Documenti\\nota.txt;absent:Documenti;absent:old.bin"

abort() { # name env... -- command...
  name=$1; shift
  img="$work/$name.img"
  [ -f "$img" ] || cp "$partition" "$img"
  set +e
  env "$@" > /dev/null 2>&1
  code=$?
  set -e
  [ "$code" -eq 86 ] || { echo "abort $name exit $code" >&2; exit 1; }
  wrap "$img" "$name"
}
abort v3-abort-replace-stage3 OPENHDD_TEST_ABORT_AT_STAGE=3 "$tool" --image "$work/v3-abort-replace-stage3.img" --replace "$work/r.bin" old.bin
case_line v3-abort-replace-stage3 repair "$windows"
abort v3-abort-replace-aside OPENHDD_TEST_ABORT_AFTER_ASIDE=1 "$tool" --image "$work/v3-abort-replace-aside.img" --replace "$work/r.bin" old.bin
case_line v3-abort-replace-aside repair "found:$O|716800;optional:$O|old.bin;$G|Documenti\\grande.bin;$N|Documenti\\nota.txt"
abort v3-abort-replace-stage5 OPENHDD_TEST_ABORT_AT_STAGE=5 "$tool" --image "$work/v3-abort-replace-stage5.img" --replace "$work/r.bin" old.bin
case_line v3-abort-replace-stage5 repair "$R|old.bin;found:$O|716800;$G|Documenti\\grande.bin;$N|Documenti\\nota.txt"
cp "$partition" "$work/v3-abort-move-stage3.img"
"$tool" --image "$work/v3-abort-move-stage3.img" --mkdir "" Archivio > /dev/null
abort v3-abort-move-stage3 OPENHDD_TEST_ABORT_AT_STAGE=3 "$tool" --image "$work/v3-abort-move-stage3.img" --move Archivio Documenti old.bin
case_line v3-abort-move-stage3 repair "found:$O|716800;found:$G|3145728;found:$N|68"
abort v3-abort-tree-stage3 OPENHDD_TEST_ABORT_AT_STAGE=3 "$tool" --image "$work/v3-abort-tree-stage3.img" --manifest "$work/tree.manifest"
case_line v3-abort-tree-stage3 repair "$windows"

# v3.1: many small files in one batch (the root index outgrows its index
# root), a move and a rename cut while the entry has both names (kept for
# the Mac's journal recovery after chkdsk) and a cancelled copy.
mkdir -p "$work/small"
: > "$work/small.manifest"
record D Piccoli >> "$work/small.manifest"
small_specs=
n=1
while [ "$n" -le 300 ]; do
  head -c $((n * 11)) /dev/urandom > "$work/small/s$n.jpg"
  record F "$work/small/s$n.jpg" Piccoli "s$n.jpg" 0 >> "$work/small.manifest"
  case "$n" in 1|15|16|17|150|300) small_specs="$small_specs;$(h "$work/small/s$n.jpg")|Piccoli\\s$n.jpg" ;; esac
  n=$((n + 1))
done
img="$work/small.img"; cp "$partition" "$img"
"$tool" --image "$img" --manifest "$work/small.manifest" > /dev/null
wrap "$img" v31-committed-small
case_line v31-committed-small clean "$windows$small_specs"
cp "$partition" "$work/v31-abort-move-twonames.img"
"$tool" --image "$work/v31-abort-move-twonames.img" --mkdir "" Archivio > /dev/null
abort v31-abort-move-twonames OPENHDD_TEST_ABORT_WITH_TWO_NAMES=1 "$tool" --image "$work/v31-abort-move-twonames.img" --move Archivio Documenti
case_line v31-abort-move-twonames repair "$O|old.bin;found:$G|3145728;found:$N|68"
abort v31-abort-rename-twonames OPENHDD_TEST_ABORT_WITH_TWO_NAMES=1 "$tool" --image "$work/v31-abort-rename-twonames.img" --rename old.bin nuovo.bin
case_line v31-abort-rename-twonames repair "found:$O|716800;$G|Documenti\\grande.bin;$N|Documenti\\nota.txt"
img="$work/cancel.img"; cp "$partition" "$img"
OPENHDD_TEST_SLOW_WRITE_MS=30 "$tool" --image "$img" --manifest "$work/tree.manifest" > /dev/null 2>&1 &
pid=$!
sleep 1
kill -INT "$pid" 2>/dev/null || true
wait "$pid" || true
"$tool" --check-image "$img" | grep -q '^dirty=0 .* pending=0 code=0'
wrap "$img" v31-cancelled
case_line v31-cancelled clean "$windows;absent:Album"

# Power-cut samples. The campaign adds its own fixture (target.bin for a
# replacement, Foto/Estate/b.bin for a move) to the Windows base; the old
# target.bin content must never be lost.
for spec in replace:512 replace:4096 move:512 tree:512 rename:512; do
  op=${spec%:*}; sector=${spec#*:}
  OPENHDD_CAMPAIGN_EDIT=$op OPENHDD_TEST_POWERCUT_SECTOR=$sector OPENHDD_CAMPAIGN_KEEP="$work/fixture-$op-$sector" \
    "$root/Tests/run-powercut-campaign.sh" "$partition" "$work/samples-$op-$sector" 1 | tail -3
  extra=
  case "$op" in
    # Once the new file is published the old one is removed on purpose:
    # either content must survive.
    replace) extra=";found:$(h "$work/fixture-$op-$sector/target.bin")|921600|$(h "$work/fixture-$op-$sector/new.bin")|2150400" ;;
    move) extra=";found:$(h "$work/fixture-$op-$sector/new.bin")|2150400" ;;
  esac
  for sample in "$work"/samples-$op-$sector/*.img; do
    name=v3-$op-$(basename "$sample" .img)
    wrap "$sample" "$name"
    case_line "$name" repair "$windows$extra"
  done
done
ls "$out"/*.vhd | wc -l
