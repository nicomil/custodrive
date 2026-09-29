#!/usr/bin/env python3
"""Minimal client for the OpenHDDCopy edit-session protocol, used by tests.

Messages are NUL-terminated fields; the first field is the number of fields
that follow. The tool answers every request with one message whose first
field is "ok" or "error" and whose last field is the captured diagnostics.
"""
import subprocess


class Session:
    def __init__(self, argv, env=None):
        self.process = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.buffer = b""
        ready = self.receive()
        if ready != ["ready"]:
            raise RuntimeError("session did not start: %r %s" % (ready, self.stderr()))

    def stderr(self):
        return self.process.stderr.read().decode(errors="replace") if self.process.poll() is not None else ""

    def _field(self):
        while b"\0" not in self.buffer:
            chunk = self.process.stdout.read1(65536)
            if not chunk:
                raise EOFError("session closed")
            self.buffer += chunk
        field, self.buffer = self.buffer.split(b"\0", 1)
        return field.decode()

    def receive(self):
        count = int(self._field())
        return [self._field() for _ in range(count)]

    def send(self, *fields):
        data = str(len(fields)).encode() + b"\0" + b"".join(f.encode() + b"\0" for f in fields)
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def call(self, *fields):
        self.send(*fields)
        return self.receive()

    def listing(self, path=""):
        reply = self.call("list", path)
        if reply[0] != "ok":
            raise RuntimeError("list %r failed: %r" % (path, reply))
        body = reply[1:-1]
        return {body[i]: (int(body[i + 1]), int(body[i + 2])) for i in range(0, len(body), 5)}

    def end(self):
        self.send("end")
        ended = self.receive()
        self.process.stdin.close()
        code = self.process.wait()
        return ended, code, self.process.stderr.read().decode(errors="replace")
