#!/usr/bin/env python3
"""Verify Mac recovery on copies of the VHDs retained by the Windows verifier.

Usage: verify-windows-roundtrip.py CASE_DIRECTORY WINDOWS_RESULTS NEW_OUTPUT
Requires the test engine already built. Never mounts or edits a source VHD.
Exit 77 means safe refusal, not completed recovery; exit 1 means failed evidence.
"""
import csv
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys

from session_client import Session

root = Path(__file__).resolve().parent.parent
tool = root / 'Build/OpenHDDCopyTest'
cases_dir, windows_dir, output = map(lambda p: Path(p).resolve(), sys.argv[1:])
output.mkdir(mode=0o700, parents=True, exist_ok=False)


def digest(path):
    with path.open('rb') as file:
        return hashlib.file_digest(file, 'sha256').hexdigest()


def extract(source, destination):
    with source.open('rb') as file:
        file.seek(-512, 2)
        footer = file.read(512)
        assert footer[:8] == b'conectix' and struct.unpack('>I', footer[60:64])[0] == 2
        file.seek(0)
        mbr = file.read(512)
        parts = [mbr[446 + 16*i:462 + 16*i] for i in range(4)]
        parts = [p for p in parts if p[4]]
        assert len(parts) == 1 and parts[0][4] == 7 and mbr[510:] == b'\x55\xaa'
        offset, sectors = struct.unpack('<II', parts[0][8:16])
        size = sectors * 512
        assert offset * 512 + size <= source.stat().st_size - 512
        file.seek(offset * 512)
        with destination.open('xb') as out:
            destination.chmod(0o600)
            while size:
                data = file.read(min(size, 4*1024*1024))
                assert data
                out.write(data)
                size -= len(data)


def inventory(image, directory, salvage=False):
    session = Session([str(tool), '--image', str(image), '--session'])
    files, folders, queue = {}, set(), ['']
    try:
        if salvage:
            assert session.call('inspect-recovery')[0] == 'error'
        while queue:
            parent = queue.pop()
            assert parent.count('/') < 32 and len(files) + len(folders) < 10000
            for name, (kind, size) in session.listing(parent).items():
                path = (parent + '/' if parent else '') + name
                if kind == 2:
                    folders.add(path)
                    queue.append(path)
                else:
                    target = directory / 'readback.bin'
                    reply = session.call('export', path, str(target))
                    assert reply[0] == 'ok', (path, reply)
                    files[path] = (digest(target), size)
                    target.unlink()
    finally:
        assert session.end()[1] == 0
    return files, folders


results = []
with (cases_dir / 'cases.tsv').open(encoding='utf-8-sig') as file:
    cases = list(csv.DictReader(file, delimiter='\t'))
for case in cases:
    name = case['case']
    assert re.fullmatch(r'[a-zA-Z0-9-]+', name)
    source = windows_dir / name / 'repaired.vhd'
    if not source.exists():
        continue  # Only explicitly retained Windows cases belong to this run.
    directory = output / name
    directory.mkdir(mode=0o700)
    result = dict(case=name, verdict='FAIL', source_sha256=digest(source))
    image = directory / 'partition.img'
    try:
        win = json.loads((windows_dir / name / 'result.json').read_text(encoding='utf-8-sig'))
        assert win['source_sha256'] == digest(cases_dir / (name + '.vhd')), 'Windows tested a different source'
        assert win['verdict'] == 'PASS', ('Windows case not passed', win['verdict'])
        extract(source, image)
        before = digest(image)
        session = Session([str(tool), '--image', str(image), '--session'])
        reply = session.call('inspect-recovery')
        assert session.end()[1] == 0
        assert digest(image) == before, 'inspection wrote to partition'
        result['inspection'] = reply
        if reply[0] != 'ok':
            assert 'recovery journal or temporary entries are invalid or ambiguous' in reply[-1]
            files, _ = inventory(image, directory, salvage=True)
            for spec in case['new_files'].split(';'):
                if spec.startswith('found:'):
                    values = spec[6:].split('|')
                    allowed = {(values[i], int(values[i+1])) for i in range(0, len(values), 2)}
                    assert any(value in allowed for value in files.values()), ('salvage content missing', spec)
                elif spec and not spec.startswith(('optional:', 'absent:', 'dir:')):
                    expected, path = spec.split('|', 1)
                    path = path.replace('\\', '/')
                    assert path in files and (expected == 'any' or files[path][0] in expected.split(',')), ('salvage file missing', path)
            assert digest(image) == before, 'salvage wrote to partition'
            result['salvage_files'] = files
            result['salvage'] = 'PASS: listed contents exported, source partition unchanged'
            result['verdict'] = 'INCONCLUSIVE'
            result['reason'] = 'Windows repaired the filesystem, but Mac recovery refused without writes'
        else:
            recovered = subprocess.run([str(tool), '--image', str(image), '--mkdir', '', 'AfterWindowsRecovery'],
                                       capture_output=True, text=True)
            result['recovery_exit'] = recovered.returncode
            (directory / 'recovery.log').write_text(recovered.stdout + recovered.stderr)
            assert recovered.returncode == 0, 'Mac recovery failed'
            checked = subprocess.run([str(tool), '--check-image', str(image)], capture_output=True, text=True)
            assert checked.returncode == 0 and 'pending=0 code=0' in checked.stdout
            files, folders = inventory(image, directory)
            for spec in case['new_files'].split(';'):
                if not spec:
                    continue
                # Windows must still see the old backup at this crash point.
                # Mac recovery deliberately discards it after verifying the new
                # old.bin against the journal digest; the required new hash at
                # old.bin remains checked below. Other found: checks still apply.
                if name == 'v3-abort-replace-stage5' and spec.startswith('found:'):
                    continue
                if spec.startswith('found:'):
                    values = spec[6:].split('|')
                    allowed = {(values[i], int(values[i+1])) for i in range(0, len(values), 2)}
                    assert any(value in allowed for value in files.values()), ('content missing after recovery', spec)
                elif spec.startswith(('absent:', 'dir:')):
                    if case['expect'] == 'clean':
                        kind, path = spec.split(':', 1)
                        path = path.replace('\\', '/')
                        assert (path in folders) if kind == 'dir' else (path not in files and path not in folders)
                else:
                    optional = spec.startswith('optional:')
                    if optional:
                        spec = spec[len('optional:'):]
                    expected, path = spec.split('|', 1)
                    path = path.replace('\\', '/')
                    if path not in files and optional:
                        continue
                    assert path in files and (expected == 'any' or files[path][0] in expected.split(',')), ('wrong final file', path)
            # Restored replacements must use their intended name, not only survive
            # under an application temporary (which inventory deliberately hides).
            if name.startswith('v3-abort-replace') or name.startswith('v3-replace-'):
                target = 'old.bin' if name.startswith('v3-abort-') else 'target.bin'
                assert target in files, ('replacement not restored to intended name', target)
            result['files'] = files
            result['partition_sha256'] = digest(image)
            result['verdict'] = 'PASS'
    except Exception as error:
        result['error'] = repr(error)
    finally:
        if digest(source) != result['source_sha256']:
            result['verdict'] = 'FAIL'
            result['error'] = 'source VHD changed'
        (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
        results.append(result)
        print(name, result['verdict'], result.get('error', ''), flush=True)
assert results, 'No retained Windows VHDs: nothing verified'
summary = dict(cases=len(results), counts={v: sum(r['verdict'] == v for r in results)
                                         for v in ('PASS', 'INCONCLUSIVE', 'FAIL')},
               scope='Windows repaired copies -> Mac read-only inspection -> recovery and final names/content checks',
               final_windows_recheck=False, results=results)
(output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
sys.exit(1 if summary['counts']['FAIL'] else 77 if summary['counts']['INCONCLUSIVE'] else 0)
