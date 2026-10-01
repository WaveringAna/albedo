"""Busy-host replies and reading an in-flight job notice are races the daemon E2E wake test cannot reliably force."""

import json
import os
import select
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
KERNEL = ROOT / "priv" / "python" / "albedo_kernel.py"

sys.path.insert(0, str(ROOT / "test"))
import scratch  # noqa: E402

# Temporary workspaces and homes go under this run's scratch directory, which
# is removed at exit.
scratch.claim("harness")
MAX_FRAME = 8 * 1024 * 1024
RETRY_WINDOW = 3.2  # NOTICE_RETRY plus slack; must not mistake a retry for silence


class Owner:
    """A minimal owner that answers host calls and buffers every other frame."""

    def __init__(self, modules, env=None):
        self.workspace = tempfile.mkdtemp(prefix="albedo-wake-")
        environment = dict(os.environ)
        environment.update(env or {})
        self.process = subprocess.Popen(
            [sys.executable, "-u", str(KERNEL), json.dumps(modules)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=self.workspace,
            env=environment,
            bufsize=0,
        )
        self.buffered = []

    def close(self):
        self.send({"type": "shutdown"})
        self.process.wait(timeout=10)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            assert stream is not None
            stream.close()
        self.buffered.clear()

    def send(self, message):
        data = json.dumps(message).encode()
        assert self.process.stdin is not None
        self.process.stdin.write(struct.pack(">I", len(data)) + data)
        self.process.stdin.flush()

    def recv(self, timeout=0.05):
        """One frame, or None when the kernel stays quiet for the window.
        stdout is unbuffered: a frame read ahead into a buffer is invisible to
        select(), and would stall until the next one arrives."""
        assert self.process.stdout is not None
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        size = struct.unpack(">I", self.read_exactly(4))[0]
        assert size <= MAX_FRAME, "control frame exceeds the ceiling"
        return json.loads(self.read_exactly(size))

    def read_exactly(self, size):
        assert self.process.stdout is not None
        data = b""
        while len(data) < size:
            chunk = self.process.stdout.read(size - len(data))
            assert chunk, "kernel closed its control stream"
            data += chunk
        return data

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, frame in enumerate(self.buffered):
                if predicate(frame):
                    return self.buffered.pop(index)
            frame = self.recv(timeout=max(0.05, deadline - time.monotonic()))
            if frame is not None:
                self.buffered.append(frame)
        raise AssertionError(
            f"no matching frame; buffered: {[f.get('type') for f in self.buffered]}"
        )

    def expect_no_call(self, method, window=RETRY_WINDOW):
        deadline = time.monotonic() + window
        while time.monotonic() < deadline:
            try:
                frame = self.wait_for(
                    lambda f: f.get("type") == "call" and f.get("method") == method,
                    timeout=max(0.05, deadline - time.monotonic()),
                )
            except AssertionError:
                return
            raise AssertionError(f"unexpected {method} call: {frame}")

    def invoke(self, call_id, **frame):
        self.send({"type": "invoke", "id": call_id, **frame})
        while True:
            reply = self.wait_for(
                lambda f: f.get("id") == call_id and f["type"] == "invoked"
            )
            if reply.get("ok") is True or "error" in reply:
                return reply


class WakeProtocolTest(unittest.TestCase):
    def setUp(self):
        self.owner = Owner(["run"])
        self.addCleanup(self.owner.close)
        self.assertEqual(
            self.owner.wait_for(lambda f: f.get("type") == "ready")["type"], "ready"
        )

    def start_job(self, *argv):
        reply = self.owner.invoke("j1", name="run", args=list(argv))
        self.assertTrue(reply["ok"])
        return reply["handle"]

    def wait_job_done(self):
        """Wait on the raw completion frame; awaiting the job would retire the wake."""
        start = self.owner.wait_for(lambda f: f.get("type") == "job_start")
        done = self.owner.wait_for(
            lambda f: f.get("type") == "job" and f.get("id") == start["id"]
        )
        return done

    def test_a_busy_session_is_retried_and_a_refusal_gives_up(self):
        self.start_job("echo", "retry-echo")
        self.wait_job_done()
        # Busy is retried, not dropped; a permanent refusal ends the attempts.
        frame = self.owner.wait_for(lambda f: f.get("type") == "call")
        self.owner.send(
            {
                "type": "reply",
                "id": frame["id"],
                "value": {"ok": False, "code": "busy", "message": "session is busy"},
            }
        )
        retry = self.owner.wait_for(
            lambda f: f.get("type") == "call" and f.get("method") == "jobs.completed",
            timeout=RETRY_WINDOW,
        )
        self.owner.send(
            {
                "type": "reply",
                "id": retry["id"],
                "value": {"ok": False, "code": "unavailable", "message": "no session"},
            }
        )
        self.owner.expect_no_call("jobs.completed")

    def test_a_read_result_retires_a_pending_notice(self):
        handle = self.start_job("echo", "read-echo")
        self.wait_job_done()
        # The notice is in flight (busy) when the result is read; the retry must stop.
        frame = self.owner.wait_for(lambda f: f.get("type") == "call")
        self.owner.send(
            {
                "type": "reply",
                "id": frame["id"],
                "value": {"ok": False, "code": "busy", "message": "session is busy"},
            }
        )
        tail = self.owner.invoke("t1", target={"handle": handle}, name="tail")
        self.assertIn("read-echo", tail["value"])
        self.owner.expect_no_call("jobs.completed")


if __name__ == "__main__":
    unittest.main()
