#!/bin/sh
# Edit sessions on disposable NTFS images: many operations over one
# exclusive open, browsing and exporting in between, failures reported per
# command, a marked volume after an interrupted write, end of input.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OPENHDD_TESTING=1 "$root/Scripts/build-copy-tool.sh"
build=${TMPDIR:-/tmp}/open-hdd-bridge-test
if [ ! -x "$build/ntfsprogs/mkntfs" ]; then
  "$root/Tests/run-offline-write-probe.sh" >/dev/null
fi
fixture=$(mktemp -d "${TMPDIR:-/tmp}/openhdd-session.XXXXXX")
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
image="$fixture/volume.img"
mkfile -n 128m "$image"
chmod 600 "$image"
"$build/ntfsprogs/mkntfs" -F -Q -L Session "$image" > /dev/null 2>&1

OPENHDD_TOOL="$root/Build/OpenHDDCopyTest" OPENHDD_NTFSCAT="$build/ntfsprogs/ntfscat" \
PYTHONPATH="$root/Tests" python3 - "$image" "$fixture" <<'PY'
import hashlib, os, subprocess, sys, time
from session_client import Session

image, fixture = sys.argv[1], sys.argv[2]
tool, ntfscat = os.environ["OPENHDD_TOOL"], os.environ["OPENHDD_NTFSCAT"]

def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)

def state():
    return subprocess.run([tool, "--check-image", image], capture_output=True, text=True).stdout

def content(path):
    return subprocess.run([ntfscat, "-f", image, path], capture_output=True).stdout

def manifest(name, *records):
    path = os.path.join(fixture, name)
    with open(path, "wb") as out:
        for record in records:
            for field in record:
                out.write(field.encode() + b"\0")
    return path

files = {}
for name, size in (("a.jpg", 300_000), ("b.mov", 5_000_000), ("c è.txt", 12)):
    data = os.urandom(size)
    path = os.path.join(fixture, name)
    open(path, "wb").write(data)
    files[name] = (path, data)
progress = os.path.join(fixture, "progress")
open(progress, "w").close()

session = Session([tool, "--image", image, "--session"])
if session.listing("") != {}:
    fail("fresh volume not empty: %r" % session.listing(""))

# Several operations, one exclusive open, browsing in between.
start = time.time()
reply = session.call("mkdir", progress, "", "Vacanze")
if reply[0] != "ok": fail("mkdir: %r" % reply)
reply = session.call("copy", manifest("m1", ("F", files["a.jpg"][0], "Vacanze", "a.jpg", "0"),
                                      ("F", files["b.mov"][0], "Vacanze", "b.mov", "0"),
                                      ("D", "Vacanze/Giorno è"),
                                      ("F", files["c è.txt"][0], "Vacanze/Giorno è", "c è.txt", "0")),
                     progress)
if reply[0] != "ok" or "PASS" not in reply[-1]: fail("copy: %r" % reply)
listing = session.listing("Vacanze")
if set(listing) != {"a.jpg", "b.mov", "Giorno è"} or listing["b.mov"] != (1, 5_000_000):
    fail("listing after copy: %r" % listing)
if session.listing("Vacanze/Giorno è") != {"c è.txt": (1, 12)}:
    fail("nested listing")
for command in (("rename", progress, "Vacanze/a.jpg", "Alba.jpg"),
                ("mkdir", progress, "", "Archivio"),
                ("move", progress, "Archivio", "Vacanze/Giorno è"),
                ("rename", progress, "Vacanze/Alba.jpg", "ALBA.jpg")):
    reply = session.call(*command)
    if reply[0] != "ok": fail("%s: %r" % (command[0], reply))
if set(session.listing("Vacanze")) != {"ALBA.jpg", "b.mov"}: fail("after edits: %r" % session.listing("Vacanze"))
if set(session.listing("Archivio")) != {"Giorno è"}: fail("move")

# Export (open / Quick Look) reads through the same descriptor.
exported = os.path.join(fixture, "export.mov")
reply = session.call("export", "Vacanze/b.mov", exported)
if reply[0] != "ok" or open(exported, "rb").read() != files["b.mov"][1]: fail("export")
reply = session.call("export", "Vacanze/b.mov", exported)
if reply[0] != "error": fail("export over an existing file must be refused")
reply = session.call("export", "Vacanze", os.path.join(fixture, "dir.out"))
if reply[0] != "error": fail("export of a folder must be refused")

# Refusals come back per command and leave the session usable.
for command in (("rename", progress, "Vacanze/b.mov", "ALBA.jpg"),
                ("delete", progress, "$MFT"),
                ("move", progress, "Vacanze", "Vacanze"),
                ("mkdir", progress, "Manca", "x"),
                ("bogus",)):
    reply = session.call(*command)
    if reply[0] != "error": fail("accepted %r" % (command,))
if "already exists" not in session.call("rename", progress, "Vacanze/b.mov", "alba.JPG")[-1]:
    fail("refusal text missing")
reply = session.call("copy", manifest("m2", ("F", files["a.jpg"][0], "Vacanze", "b.mov", "1")), progress)
if reply[0] != "ok": fail("replace in session: %r" % reply)
reply = session.call("delete", progress, "Archivio")
if reply[0] != "ok": fail("delete: %r" % reply)
elapsed = time.time() - start
ended, code, stderr = session.end()
if ended != ["ended"] or code != 0: fail("end: %r %d %s" % (ended, code, stderr))
if "dirty=0" not in state() or "pending=0 code=0" not in state(): fail("volume after session: " + state())
if content("/Vacanze/b.mov") != files["a.jpg"][1] or content("/Vacanze/ALBA.jpg") != files["a.jpg"][1]:
    fail("contents after session")

# Cancel inside a session: SIGINT while a copy is written undoes that copy
# and the session goes on; SIGINT while idle does not end it.
import signal, threading
big = os.path.join(fixture, "big.bin")
open(big, "wb").write(os.urandom(12_000_000))
env = dict(os.environ, OPENHDD_TEST_SLOW_WRITE_MS="40")
session = Session([tool, "--image", image, "--session"], env=env)
session.process.send_signal(signal.SIGINT)  # idle: must be ignored
time.sleep(0.3)
threading.Timer(1.0, lambda: session.process.send_signal(signal.SIGINT)).start()
reply = session.call("copy", manifest("m3", ("D", "Annullata"),
                                      ("F", big, "Annullata", "big.bin", "0")), progress)
if reply[0] != "error" or "Cancelled:" not in reply[-1]: fail("cancel in session: %r" % reply)
if "Annullata" in session.listing(""): fail("cancelled copy left its folder")
reply = session.call("mkdir", progress, "", "DopoAnnullo")
if reply[0] != "ok": fail("session unusable after cancel: %r" % reply)
ended, code, stderr = session.end()
if code != 0 or "dirty=0" not in state(): fail("after cancel: %d %s" % (code, state()))

# End of input (the app vanished) ends the session cleanly.
session = Session([tool, "--image", image, "--session"])
session.call("mkdir", progress, "", "Poi")
session.process.stdin.close()
if session.process.wait() != 0 or "Poi" not in subprocess.run(
        [os.path.join(os.path.dirname(ntfscat), "ntfsls"), "-p", "/", image],
        capture_output=True, text=True).stdout:
    fail("end of input")

# A write interrupted inside the session marks the volume; the session
# reports it and the tool exits nonzero.
env = dict(os.environ, OPENHDD_TEST_FAIL_PWRITE_AT="3")
session = Session([tool, "--image", image, "--session"], env=env)
reply = session.call("mkdir", progress, "", "Rotta")
if reply[0] != "error" or reply[2] not in ("2", "3"): fail("injected failure: %r" % reply)
if "chkdsk" not in reply[-1]: fail("no chkdsk advice")
reply = session.call("mkdir", progress, "", "Dopo")
if reply[0] != "error": fail("write accepted on a marked volume")
session.listing("")  # browsing still works
ended, code, stderr = session.end()
if code == 0: fail("marked session reported success")
if "dirty=1" not in state(): fail("volume not marked")
print("session: %d operations in %.2fs over one open" % (11, elapsed))
PY
echo 'PASS: edit session (mkdir, copy, rename, move, case rename, replace, delete, browse, export, refusals, end of input, marked volume, cancel)'
