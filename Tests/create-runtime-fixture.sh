#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output=${1:?Usage: create-runtime-fixture.sh OUTPUT.img}
test ! -e "$output" || { echo "Output already exists" >&2; exit 1; }
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
if [ ! -x "$build/ntfsprogs/mkntfs" ] || [ ! -x "$build/ntfsprogs/ntfscp" ]; then
  "$root/Tests/run-bridge-test.sh" >/dev/null 2>&1
fi
temporary=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-runtime.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM
partition="$temporary/partition.img"
mkfile -n 64m "$partition"
chmod 600 "$partition"
"$build/ntfsprogs/mkntfs" -F -Q -L OpenHDDTest "$partition" > "$temporary/mkntfs.log" 2>&1
printf 'OpenHDD runtime test\n' > "$temporary/known.txt"
printf 'café' > "$temporary/unicode.txt"
if [ "${OPENHDD_FIXTURE_WRITER:-ntfscp}" = direct ]; then
  test -x "$root/Build/OpenHDDCopy" || {
    echo 'Run Scripts/build-copy-tool.sh first' >&2
    exit 1
  }
  "$root/Build/OpenHDDCopy" --image "$partition" "$temporary/known.txt" known.txt
  "$root/Build/OpenHDDCopy" --image "$partition" "$temporary/unicode.txt" cafe.txt
elif [ "${OPENHDD_FIXTURE_WRITER:-ntfscp}" = offline ]; then
  test -x "$build/offline_image_writer" || {
    echo 'Run Tests/run-offline-write-probe.sh first' >&2
    exit 1
  }
  "$build/offline_image_writer" "$partition" "$temporary/known.txt" known.txt
  "$build/offline_image_writer" "$partition" "$temporary/unicode.txt" café.txt
else
  "$build/ntfsprogs/ntfscp" "$partition" "$temporary/known.txt" /known.txt
  "$build/ntfsprogs/ntfscp" "$partition" "$temporary/unicode.txt" /café.txt
fi
python3 - "$partition" "$output" <<'PY'
import os
import shutil
import struct
import sys
import uuid
import zlib

source, output = sys.argv[1:]
sector = 512
total_sectors = 262144  # 128 MiB
partition_first = 2048
partition_sectors = os.path.getsize(source) // sector
partition_last = partition_first + partition_sectors - 1
assert partition_last < total_sectors - 33
last = total_sectors - 1
entry_count = 128
entry_size = 128
entries = bytearray(entry_count * entry_size)
entries[:128] = struct.pack(
    '<16s16sQQQ72s',
    uuid.UUID('EBD0A0A2-B9E5-4433-87C0-68B6B72699C7').bytes_le,
    uuid.uuid4().bytes_le,
    partition_first, partition_last, 0,
    'OpenHDDTest'.encode('utf-16le').ljust(72, b'\0'))
entries_crc = zlib.crc32(entries)
disk_id = uuid.uuid4().bytes_le

def header(current, backup, entry_lba):
    fields = ('<8sIIIIQQQQ16sQIII', b'EFI PART', 0x10000, 92, 0, 0,
              current, backup, 34, last - 33, disk_id,
              entry_lba, entry_count, entry_size, entries_crc)
    data = bytearray(struct.pack(*fields))
    struct.pack_into('<I', data, 16, zlib.crc32(data))
    return data.ljust(sector, b'\0')

with open(output, 'xb') as image:
    image.truncate(total_sectors * sector)
    mbr = bytearray(sector)
    mbr[446:462] = struct.pack('<B3sB3sII', 0, b'\0\2\0', 0xEE,
                               b'\xff\xff\xff', 1, min(last, 0xFFFFFFFF))
    mbr[510:512] = b'\x55\xaa'
    image.seek(0)
    image.write(mbr)
    image.write(header(1, last, 2))
    image.write(entries)
    image.seek((last - 32) * sector)
    image.write(entries)
    image.write(header(last, 1, last - 32))
    image.seek(partition_first * sector)
    with open(source, 'rb') as partition:
        shutil.copyfileobj(partition, image, 1024 * 1024)

print(output)
PY
chmod 0444 "$output"
shasum -a 256 "$output"
