#!/bin/sh
# Recovery regressions on fresh disposable images only. ntfsfix is a fixture
# repair stand-in, not evidence of Windows/chkdsk compatibility.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
if [ ! -x "$build/ntfsprogs/ntfscp" ]; then
  "$root/Tests/run-offline-write-probe.sh" >/dev/null
fi
python3 - "$root/Build/OpenHDDCopyTest" "$build/ntfsprogs" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

tool, progs = Path(sys.argv[1]), Path(sys.argv[2])
def run(*args, code=0, env=None):
    result = subprocess.run(list(map(str, args)), capture_output=True,
                            env=dict(os.environ, **(env or {})))
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result

def copy(image, *args, **kwargs):
    return run(tool, '--image', image, *args, **kwargs)

def hash_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def read(image, path):
    return run(progs / 'ntfscat', '-f', image, path).stdout

def clean(image):
    result = run(tool, '--check-image', image).stdout
    assert result.startswith(b'dirty=0 ') and b'pending=0 code=0' in result, result

with tempfile.TemporaryDirectory(prefix='openhdd-recovery-') as directory:
    work = Path(directory)
    base = work / 'base.img'
    with base.open('wb') as f:
        f.truncate(64 * 1024 * 1024)
    base.chmod(0o600)
    run(progs / 'mkntfs', '-F', '-Q', base)
    old, new = work / 'old.txt', work / 'new.txt'
    old.write_bytes(b'original content\n')
    new.write_bytes(b'replacement content\n')
    copy(base, old, 'keep.bin', old, 'target.bin')
    copy(base, '--mkdir', '', 'Parent')
    copy(base, '--mkdir', '', 'Foto')
    copy(base, '--mkdir', 'Parent', 'Foto')
    for folder in ('Foto', 'Parent/Foto'):
        copy(base, '--dir', folder, old, 'inside.bin')

    def fresh(name):
        image = work / (name + '.img')
        shutil.copyfile(base, image)
        image.chmod(0o600)
        return image

    def repair(image):
        run(progs / 'ntfsfix', '-d', image)

    def put_journal(image, data):
        path = work / 'journal.txt'
        path.write_bytes(data)
        run(progs / 'ntfscp', image, path, '/.OpenHDD-journal')

    def body(image):
        text = read(image, '/.OpenHDD-journal')
        assert text.startswith(b'OpenHDD-Journal\t2\t')
        return text.split(b'\n', 1)[1]

    def versioned(data):
        return b'OpenHDD-Journal\t2\t' + hashlib.sha256(data).hexdigest().encode() + b'\n' + data

    def legacy(image):
        lines = []
        for line in body(image).splitlines():
            fields = line.split(b'\t')
            lines.append(b'\t'.join(fields[:5 if fields[0] == b'L' else 4]))
        put_journal(image, b'\n'.join(lines) + b'\n')

    def refused_unchanged(image):
        before = hash_file(image)
        result = copy(image, '--mkdir', '', 'After', code=1)
        assert b'stage 1' in result.stderr and b'invalid or ambiguous' in result.stderr, result.stderr
        assert hash_file(image) == before, 'refusal wrote to the image'
        assert read(image, '/keep.bin') == old.read_bytes()

    # Untrusted legacy records: same path, case aliases, noncanonical paths,
    # reserved entries, malformed tail, embedded NUL, missing final newline.
    invalid = [b'L\t\tkeep.bin\t\tkeep.bin\n',
               b'L\t\tkeep.bin\t\tKEEP.BIN\n',
               b'L\tParent\tFoto\tparent\tFoto\n',
               b'L\t/\tkeep.bin\t\tmissing.bin\n',
               b'L\t\t$MFT\t\tmissing.bin\n',
               b'L\t\tkeep.bin\t\tmissing.bin\nBAD\n',
               b'L\t\tkeep.bin\t\tmissing.bin\n\0ignored',
               b'L\t\tkeep.bin\t\tmissing.bin', b'']
    for i, data in enumerate(invalid):
        image = fresh('invalid-' + str(i))
        put_journal(image, data)
        refused_unchanged(image)

    # A valid actionable first row must not run when a later row is invalid.
    for mode in ('bad-tail', 'duplicate', 'checksum', 'sequence'):
        image = fresh(mode)
        copy(image, '--rename', 'keep.bin', 'renamed.bin', code=86,
             env={'OPENHDD_TEST_ABORT_WITH_TWO_NAMES': '1'})
        repair(image)
        data = body(image)
        if mode == 'bad-tail':
            put_journal(image, versioned(data + b'BAD\n'))
        elif mode == 'duplicate':
            put_journal(image, versioned(data + data))
        elif mode == 'checksum':
            put_journal(image, versioned(data).replace(b'renamed.bin', b'changed.bin'))
        else:
            fields = data.rstrip(b'\n').split(b'\t')
            fields[-1] = ('%016x' % (int(fields[-1], 16) + (1 << 48))).encode()
            put_journal(image, versioned(b'\t'.join(fields) + b'\n'))
        refused_unchanged(image)
        assert read(image, '/renamed.bin') == old.read_bytes()

    # Directory case renames, in root and nested; two names and temporary-only.
    # Both the new format and conservative legacy reader must preserve contents.
    for parent in ('', 'Parent/'):
        for hook in ('OPENHDD_TEST_ABORT_WITH_TWO_NAMES', 'OPENHDD_TEST_ABORT_AFTER_CASE_UNLINK'):
            for old_format in (False, True):
                image = fresh('case')
                copy(image, '--rename', parent + 'Foto', 'FOTO', code=86, env={hook: '1'})
                repair(image)
                if old_format:
                    legacy(image)
                # Repeated process deaths after applying recovery, with repair
                # in between, must be idempotent, including a restored directory.
                for _ in range(2):
                    copy(image, '--mkdir', '', 'After', code=86,
                         env={'OPENHDD_TEST_ABORT_RECOVERY_AFTER_ENTRY': '1'})
                    repair(image)
                copy(image, '--mkdir', '', 'After')
                clean(image)
                names = run(progs / 'ntfsls', '-p', '/' + parent, image).stdout.splitlines()
                recovered = next(n for n in names if n.lower() == b'foto').decode()
                assert read(image, '/' + parent + recovered + '/inside.bin') == old.read_bytes()

    # A pending directory outside a C record is not a disposable copy file.
    image = fresh('unclaimed-directory')
    copy(image, '--rename', 'Foto', 'FOTO', code=86,
         env={'OPENHDD_TEST_ABORT_WITH_TWO_NAMES': '1'})
    repair(image)
    put_journal(image, b'L\t\tkeep.bin\t\tmissing.bin\n')
    refused_unchanged(image)

    # Legacy replacement: old-only is recoverable; two different files are
    # ambiguous without recorded identities and must both be preserved.
    for published in (False, True):
        image = fresh('legacy-replace')
        env = {'OPENHDD_TEST_ABORT_AT_STAGE': '5'} if published else {'OPENHDD_TEST_ABORT_AFTER_ASIDE': '1'}
        copy(image, '--replace', new, 'target.bin', code=86, env=env)
        repair(image)
        legacy(image)
        if published:
            refused_unchanged(image)
        else:
            # Die halfway through restoring the old name: two links to old data.
            copy(image, '--mkdir', '', 'After', code=86,
                 env={'OPENHDD_TEST_ABORT_WITH_TWO_NAMES': '1'})
            repair(image)
            copy(image, '--mkdir', '', 'After')
            clean(image)
            assert read(image, '/target.bin') == old.read_bytes()

    # Corrupted replacement bytes with the same MFT identity: preserve backup.
    image = fresh('changed-replacement')
    copy(image, '--replace', new, 'target.bin', code=86, env={'OPENHDD_TEST_ABORT_AT_STAGE': '5'})
    repair(image)
    run(progs / 'ntfscp', image, old, '/target.bin')
    refused_unchanged(image)

    # New folder names must be checked in the engine, including manifest input.
    for name in ('CON', 'Bad:Name', 'trailing.', 'trailing ', '.openhdd-test'):
        image = fresh('bad-folder')
        manifest = work / 'manifest'
        manifest.write_bytes(b'D\0Good\0D\0Good/' + name.encode() + b'\0')
        before = hash_file(image)
        copy(image, '--manifest', manifest, code=1)
        assert hash_file(image) == before, name
    # Every generated journal must use the same canonical paths its reader accepts.
    image = fresh('noncanonical-copy')
    before = hash_file(image)
    copy(image, '--dir', 'Parent//Foto', '--replace', new, 'inside.bin', code=2)
    assert hash_file(image) == before
    image = fresh('system-protection')
    for args in (('--mkdir', '$Extend', 'Test'), ('--mkdir', '', '$Reserved'),
                 ('--replace', new, '$MFT')):
        before = hash_file(image)
        copy(image, *args, code=1)
        assert hash_file(image) == before, args

print('PASS: untrusted journals refused without writes; directory recovery and repeated recovery;')
print('legacy ambiguity preserved; replacement digest checked; folder names and system paths protected.')
print('Image-only regressions: Windows/chkdsk and physical power loss remain unverified here.')
PY
