#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 WINDOWS_NTFS_IMAGE_A [WINDOWS_NTFS_IMAGE_B]" >&2
  exit 64
fi

case_id=$(date -u +%Y%m%dT%H%M%SZ)-$$
evidence="$root/Build/evidence/journal/$case_id"
mkdir -p "$evidence"
chmod 700 "$evidence"
build="${TMPDIR:-/tmp}/open-hdd-journal-probe"
mkdir -p "$build"

PROJECT_DIR="$root" "$root/Scripts/build-ntfs3g.sh" >/dev/null
cc -std=c11 -O2 -arch arm64 -mmacosx-version-min=15.4 \
  -Wall -Wextra -Werror \
  -I "$root/vendor/ntfs-3g-2026.7.7/include" \
  -I "$root/Build/ntfs3g" \
  "$root/Tests/ntfs_journal_probe.c" \
  "$root/Build/ntfs3g/libntfs-3g/.libs/libntfs-3g.a" \
  -framework CoreFoundation \
  -o "$build/ntfs_journal_probe"

index=0
overall=0
probe_summary=""
for image in "$@"; do
  index=$((index + 1))
  if [ -L "$image" ] || [ ! -f "$image" ]; then
    echo "REFUSED: image $index is not a regular non-symlink file" >&2
    overall=77
    probe_summary="$probe_summary image-$index=REFUSED"
    continue
  fi
  source_identity=$(stat -f '%d:%i:%l:%z' "$image")
  source_links=$(printf '%s\n' "$source_identity" | awk -F: '{print $3}')
  if [ "$source_links" -ne 1 ]; then
    echo "REFUSED: image $index has unexpected hard links" >&2
    overall=77
    probe_summary="$probe_summary image-$index=REFUSED"
    continue
  fi
  copy="$evidence/baseline-$index.img"
  cp -p "$image" "$copy"
  chmod 600 "$copy"
  if [ "$source_identity" != "$(stat -f '%d:%i:%l:%z' "$image")" ]; then
    echo "REFUSED: image $index identity changed during copy" >&2
    overall=77
    probe_summary="$probe_summary image-$index=REFUSED"
    continue
  fi
  size=$(stat -f '%z' "$copy")
  hash=$(shasum -a 256 "$copy" | awk '{print $1}')
  before="$hash"
  set +e
  "$build/ntfs_journal_probe" "$copy" > "$evidence/inspection-$index.json" \
    2> "$evidence/inspection-$index.log"
  probe_status=$?
  set -e
  after=$(shasum -a 256 "$copy" | awk '{print $1}')
  if [ "$before" != "$after" ]; then
    echo "FAIL: probe $index changed image hash" >&2
    overall=77
  fi
  printf '%s\n' "probe=$index operation=read-only image_bytes=$size hash_before=$before hash_after=$after status=$probe_status" \
    >> "$evidence/io-trace.jsonl"
  probe_summary="$probe_summary image-$index=$probe_status"
  if [ "$probe_status" -ne 0 ]; then overall=77; fi
done

inspection_result=PASS
if [ "$overall" -ne 0 ]; then inspection_result=INCONCLUDENTE; fi

cat > "$evidence/manifest.json" <<EOF
{
  "schema": "openhdd.journal-evidence.v1",
  "gate": "G1",
  "status": "INCONCLUDENTE",
  "writer": "REFUSED_G1_NOT_PASSED",
  "images": $#,
  "probe_summary": "$probe_summary",
  "binary": "Tests/ntfs_journal_probe.c",
  "vendor": "ntfs-3g-2026.7.7",
  "trace_contains_file_data": false
}
EOF
cat > "$evidence/case.json" <<EOF
{
  "case": "read-only-log-inspection",
  "requirements": ["R01", "R09", "R11"],
  "expected": "inspection only; zero target writes; unchanged image hash",
  "result": "$inspection_result",
  "gate_result": "INCONCLUDENTE",
  "missing": ["Windows-formatted independent baselines", "G1 binary protocol evidence", "G2 recovery"]
}
EOF
cat > "$evidence/report.md" <<EOF
# Journal probe $case_id

- Read-only image inspection: $inspection_result.
- Image hashes before/after: equal.
- Target writes: 0 by construction.
- G1: INCONCLUDENTE. The probe does not generate transactions.
- G2: NON_ESEGUITO. No Windows recovery claim is made.

Evidence kept at this directory. Missing protocol evidence cannot be replaced
by a green parser or by a normal mount/unmount cycle.
EOF
find "$evidence" -type f ! -name SHA256SUMS -exec shasum -a 256 {} + > "$evidence/SHA256SUMS"

if [ "$overall" -ne 0 ]; then
  echo "INCONCLUDENTE: journal inspection incomplete; evidence=$evidence" >&2
  exit 77
fi
echo "PASS: read-only journal inspection; G1 INCONCLUDENTE; evidence=$evidence"
exit 77
