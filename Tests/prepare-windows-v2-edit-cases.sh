#!/bin/sh
# Builds the Windows verification set for v2 edits (delete, rename, new
# folder). The edits target a folder "Edit" that OpenHDD adds to the
# Windows-formatted base first, so every file Windows put there must stay
# intact in every case.
#
# Usage: Tests/prepare-windows-v2-edit-cases.sh BASE.vhd BASE-files.sha256 OUT_DIR
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base_vhd=$1
base_list=$2
out=$3
tool="$root/Build/OpenHDDCopyTest"
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
mkdir -p "$out"
work=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-v2e.XXXXXX")
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

# The edit target, written by the v1 copy engine.
dd if=/dev/urandom of="$work/foto.bin" bs=1k count=900 status=none
dd if=/dev/urandom of="$work/doc.bin" bs=1k count=120 status=none
"$tool" --image "$partition" --mkdir "" Edit > /dev/null
"$tool" --image "$partition" --mkdir Edit "Da cancellare" > /dev/null
"$tool" --image "$partition" --mkdir Edit "Cartella è" > /dev/null
"$tool" --image "$partition" --dir Edit "$work/foto.bin" "foto.bin" > /dev/null
"$tool" --image "$partition" --dir "Edit/Da cancellare" "$work/doc.bin" "a.bin" "$work/foto.bin" "b.bin" > /dev/null
"$tool" --image "$partition" --dir "Edit/Cartella è" "$work/doc.bin" "dentro.bin" > /dev/null
"$tool" --check-image "$partition" | grep -q '^dirty=0 .* code=0'

printf 'case\texpect\tnew_files\n' > "$out/cases.tsv"
cp "$base_list" "$out/base-files.sha256"
F=$(h "$work/foto.bin"); D=$(h "$work/doc.bin")

wrap "$partition" edit-prepared
printf 'edit-prepared\tclean\t%s|Edit\\foto.bin;%s|Edit\\Da cancellare\\a.bin;%s|Edit\\Cartella è\\dentro.bin\n' "$F" "$D" "$D" >> "$out/cases.tsv"

img="$work/c-delete.img"; cp "$partition" "$img"
"$tool" --image "$img" --delete "Edit/Da cancellare" "Edit/foto.bin" > /dev/null
wrap "$img" edit-committed-delete
printf 'edit-committed-delete\tclean\tabsent:Edit\\Da cancellare;absent:Edit\\foto.bin;%s|Edit\\Cartella è\\dentro.bin\n' "$D" >> "$out/cases.tsv"

img="$work/c-rename.img"; cp "$partition" "$img"
"$tool" --image "$img" --rename "Edit/foto.bin" "Foto rinominata.bin" > /dev/null
"$tool" --image "$img" --rename "Edit/Cartella è" "Cartella nuova" > /dev/null
"$tool" --image "$img" --rename "Edit/Da cancellare" "DA CANCELLARE" > /dev/null
wrap "$img" edit-committed-rename
printf 'edit-committed-rename\tclean\t%s|Edit\\Foto rinominata.bin;absent:Edit\\foto.bin;%s|Edit\\Cartella nuova\\dentro.bin;absent:Edit\\Cartella è;%s|Edit\\DA CANCELLARE\\a.bin\n' "$F" "$D" "$D" >> "$out/cases.tsv"

img="$work/c-mkdir.img"; cp "$partition" "$img"
"$tool" --image "$img" --mkdir "Edit" "Nuova è" > /dev/null
"$tool" --image "$img" --mkdir "Edit/Nuova è" "Più dentro" > /dev/null
wrap "$img" edit-committed-mkdir
printf 'edit-committed-mkdir\tclean\tdir:Edit\\Nuova è\\Più dentro;%s|Edit\\foto.bin\n' "$F" >> "$out/cases.tsv"

for stage in 3 6; do
  for op in delete rename; do
    img="$work/a-$op-$stage.img"; cp "$partition" "$img"
    set +e
    if [ "$op" = delete ]; then
      OPENHDD_TEST_ABORT_AT_STAGE=$stage "$tool" --image "$img" --delete "Edit/Da cancellare" > /dev/null 2>&1
    else
      OPENHDD_TEST_ABORT_AT_STAGE=$stage "$tool" --image "$img" --rename "Edit/Cartella è" "Cartella nuova" > /dev/null 2>&1
    fi
    set -e
    wrap "$img" "edit-abort-$op-stage$stage"
    printf 'edit-abort-%s-stage%s\trepair\toptional:%s|Edit\\foto.bin\n' "$op" "$stage" "$F" >> "$out/cases.tsv"
  done
done

for op in delete rename; do
  for sector in 512 4096; do
    OPENHDD_CAMPAIGN_EDIT=$op OPENHDD_TEST_POWERCUT_SECTOR=$sector \
      "$root/Tests/run-powercut-campaign.sh" "$partition" "$work/samples-$op" 1 | tail -2
  done
  for sample in "$work"/samples-$op/*.img; do
    name=$(basename "$sample" .img)
    wrap "$sample" "edit-$op-$name"
    printf 'edit-%s-%s\trepair\toptional:%s|Edit\\foto.bin\n' "$op" "$name" "$F" >> "$out/cases.tsv"
  done
done
ls "$out" | wc -l
