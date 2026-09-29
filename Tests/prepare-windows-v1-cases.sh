#!/bin/sh
# Builds the Windows verification set for the v1 copy protocol (gate V2).
#
# Input: a fixed VHD formatted by Windows with one MBR NTFS partition that
# holds /old.bin (plus any other files), and the list of its files' SHA-256
# written on Windows ("hash  length  relative\path" per line).
# Output: one VHD per case, identical to the input except for the partition
# bytes written by OpenHDD, and cases.tsv describing what Windows must see.
#
# Usage: Tests/prepare-windows-v1-cases.sh BASE.vhd BASE-files.sha256 OUT_DIR
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
base_vhd=$1
base_list=$2
out=$3
tool="$root/Build/OpenHDDCopyTest"
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
mkdir -p "$out"
git -C "$root" rev-parse HEAD > "$out/source-commit.txt"
git -C "$root" diff HEAD -- Sources Scripts Tests > "$out/source-diff.patch"
shasum -a 256 "$tool" > "$out/engine.sha256"
work=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-v2.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

geometry=$(python3 - "$base_vhd" <<'EOF'
import struct, sys
data = open(sys.argv[1], 'rb')
data.seek(-512, 2)
footer = data.read(512)
assert footer[:8] == b'conectix' and struct.unpack('>I', footer[60:64])[0] == 2, 'fixed VHD expected'
data.seek(0)
mbr = data.read(512)
parts = [mbr[446 + 16 * i:462 + 16 * i] for i in range(4)]
parts = [p for p in parts if p[4]]
assert len(parts) == 1 and parts[0][4] == 7, 'one NTFS MBR partition expected'
lba, sectors = struct.unpack('<II', parts[0][8:16])
print(lba, sectors)
EOF
)
lba=${geometry% *}
sectors=${geometry#* }
partition="$work/base.img"
dd if="$base_vhd" of="$partition" bs=512 skip="$lba" count="$sectors" status=none
chmod 600 "$partition"
"$tool" --check-image "$partition" | grep -q '^dirty=0 .* code=0'

wrap() { # partition image -> case VHD
  cp "$base_vhd" "$out/$2.vhd"
  dd if="$1" of="$out/$2.vhd" bs=512 seek="$lba" conv=notrunc status=none
}

printf 'case\texpect\tnew_files\n' > "$out/cases.tsv"
cp "$base_list" "$out/base-files.sha256"

# New content, with hashes Windows must find after a successful copy.
printf 'Nuovo file da OpenHDD — città, perché, 日本語\n' > "$work/unicode.txt"
dd if=/dev/urandom of="$work/foto.bin" bs=1k count=5000 status=none
dd if=/dev/urandom of="$work/nota.bin" bs=1k count=33 status=none
: > "$work/vuoto.dat"
h() { shasum -a 256 "$1" | awk '{print $1}'; }

committed="$work/committed.img"
cp "$partition" "$committed"
"$tool" --image "$committed" "$work/unicode.txt" "Città è bella.txt" \
  "$work/foto.bin" "foto 2026.bin" "$work/vuoto.dat" "vuoto.dat" > /dev/null
"$tool" --image "$committed" --dir Documenti "$work/nota.bin" "nuovo documento.bin" > /dev/null
wrap "$committed" committed
printf 'committed\tclean\t%s|Città è bella.txt;%s|foto 2026.bin;%s|vuoto.dat;%s|Documenti\\nuovo documento.bin\n' \
  "$(h "$work/unicode.txt")" "$(h "$work/foto.bin")" "$(h "$work/vuoto.dat")" \
  "$(h "$work/nota.bin")" >> "$out/cases.tsv"

# Interruptions at named stages (process death; page cache survives).
for stage in 3 5 6; do
  image="$work/abort-$stage.img"
  cp "$partition" "$image"
  set +e
  OPENHDD_TEST_ABORT_AT_STAGE=$stage "$tool" --image "$image" \
    "$work/foto.bin" "foto 2026.bin" > /dev/null 2>&1
  set -e
  wrap "$image" "abort-stage$stage"
  printf 'abort-stage%s\trepair\toptional:%s|foto 2026.bin\n' "$stage" \
    "$(h "$work/foto.bin")" >> "$out/cases.tsv"
done

# Power cuts with a volatile cache, torn at 512 bytes and at 4 KiB.
for sector in 512 4096; do
  code=0
  OPENHDD_TEST_POWERCUT_SECTOR=$sector \
    "$root/Tests/run-powercut-campaign.sh" "$partition" "$work/samples" 2 > "$work/campaign.log" 2>&1 || code=$?
  cat "$work/campaign.log"
  [ "$code" -eq 0 ] || [ "$code" -eq 77 ] || exit "$code"
done
for sample in "$work"/samples/*.img; do
  name=$(basename "$sample" .img)
  wrap "$sample" "$name"
  printf '%s\trepair\toptional:any|new.bin\n' "$name" >> "$out/cases.tsv"
done
ls "$out"
