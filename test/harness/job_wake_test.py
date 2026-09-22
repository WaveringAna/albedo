"""The wake protocol: unfinished jobs tell the host, reads retire the notice.

The owner here is a fake daemon: it answers the kernel's host calls, so the
bash plugin's notice machinery can be exercised against the real kernel without
gleam. The replies cover the whole contract: accepted, refused with busy
(retried), refused otherwise (given up), and no call at all when the job was
awaited or its result was already read.
"""
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
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=self.workspace, env=environment)
        self.buffered = []
        self.calls = []          # host calls the owner has seen, in order
        self.answers = []        # canned answers, popped per call; default ok

    def close(self):
        self.send({"type": "shutdown"})
        self.process.wait(timeout=10)
        for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
            stream.close()
        self.buffered.clear()

    def send(self, message):
        data = json.dumps(message).encode()
        self.process.stdin.write(struct.pack(">I", len(data)) + data)
        self.process.stdin.flush()

    def recv(self, timeout=0.05):
        """One frame, or None when the kernel stays quiet for the window."""
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        header = self.process.stdout.read(4)
        size = struct.unpack(">I", header)[0]
        assert size <= MAX_FRAME, "control frame exceeds the ceiling"
        return json.loads(self.process.stdout.read(size))

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, frame in enumerate(self.buffered):
                if predicate(frame):
                    return self.buffered.pop(index)
            frame = self.recv(timeout=max(0.05, deadline - time.monotonic()))
            if frame is not None:
                self.buffered.append(frame)
        raise AssertionError(f"no matching frame; buffered: "
                             f"{[f.get('type') for f in self.buffered]}")

    def expect_no_call(self, method, window=RETRY_WINDOW):
        deadline = time.monotonic() + window
        while time.monotonic() < deadline:
            try:
                frame = self.wait_for(
                    lambda f: f.get("type") == "call" and f.get("method") == method,
                    timeout=max(0.05, deadline - time.monotonic()))
            except AssertionError:
                return
            raise AssertionError(f"unexpected {method} call: {frame}")

    def serve_calls(self):
        """Answer every host call currently waiting; returns the wake payloads."""
        notices = []
        while True:
            try:
                frame = self.wait_for(lambda f: f.get("type") == "call", timeout=0.4)
            except AssertionError:
                return notices
            self.calls.append(frame)
            notices.append(frame)
            answer = self.answers.pop(0) if self.answers else {"ok": True, "value": "delivered"}
            self.send({"type": "reply", "id": frame["id"], "value": answer})

    def invoke(self, call_id, **frame):
        self.send({"type": "invoke", "id": call_id, **frame})
        while True:
            reply = self.wait_for(lambda f: f.get("id") == call_id and f["type"] == "invoked")
            if reply.get("ok") is True or "error" in reply:
                return reply


class WakeProtocolTest(unittest.TestCase):
    def setUp(self):
        self.owner = Owner(["bash"])
        self.addCleanup(self.owner.close)
        self.assertEqual(self.owner.wait_for(lambda f: f.get("type") == "ready")["type"], "ready")

    def start_job(self, command):
        reply = self.owner.invoke("j1", name="bash", args=[command])
        self.assertTrue(reply["ok"])
        return reply["handle"]

    def wait_job_done(self):
        """Wait on the raw completion frame; awaiting the job would retire the wake."""
        start = self.owner.wait_for(lambda f: f.get("type") == "job_start")
        done = self.owner.wait_for(
            lambda f: f.get("type") == "job" and f.get("id") == start["id"])
        return done

    def read_notice(self, frame):
        args = frame["args"]
        self.assertIn("display", args)
        self.assertIn("text", args)
        self.assertIn("<system-note>", args["text"])
        return args

    def test_an_unread_job_completion_reports_to_the_host(self):
        handle = self.start_job("echo wake-echo")
        self.wait_job_done()
        notices = self.owner.serve_calls()
        wakes = [f for f in notices if f["method"] == "jobs.completed"]
        self.assertEqual(len(wakes), 1)
        args = self.read_notice(wakes[0])
        self.assertEqual(args["exit_code"], 0)
        self.assertIn("wake-echo", args["text"])
        self.assertIsNone(args["host"])
        self.owner.expect_no_call("jobs.completed")

    def test_a_busy_session_is_retried_until_accepted(self):
        handle = self.start_job("echo retry-echo")
        self.wait_job_done()
        # First attempt: busy. The plugin must try again rather than give up.
        frame = self.owner.wait_for(lambda f: f.get("type") == "call")
        self.owner.send({"type": "reply", "id": frame["id"],
                         "value": {"ok": False, "code": "busy", "message": "session is busy"}})
        retry = self.owner.wait_for(
            lambda f: f.get("type") == "call" and f.get("method") == "jobs.completed",
            timeout=RETRY_WINDOW)
        self.owner.send({"type": "reply", "id": retry["id"],
                         "value": {"ok": True, "value": "delivered"}})
        self.owner.expect_no_call("jobs.completed")

    def test_a_permanent_refusal_gives_up_without_retrying(self):
        handle = self.start_job("echo refused-echo")
        self.wait_job_done()
        frame = self.owner.wait_for(lambda f: f.get("type") == "call")
        self.owner.send({"type": "reply", "id": frame["id"],
                         "value": {"ok": False, "code": "unavailable", "message": "no session"}})
        self.owner.expect_no_call("jobs.completed")

    def test_an_awaited_job_never_reports(self):
        handle = self.start_job("echo awaited-echo")
        self.owner.invoke("w1", target={"handle": handle}, **{"await": True})
        self.owner.expect_no_call("jobs.completed")

    def test_a_read_result_retires_a_pending_notice(self):
        handle = self.start_job("echo read-echo")
        self.wait_job_done()
        # The notice is in flight (busy) when the result is read; the retry must stop.
        frame = self.owner.wait_for(lambda f: f.get("type") == "call")
        self.owner.send({"type": "reply", "id": frame["id"],
                         "value": {"ok": False, "code": "busy", "message": "session is busy"}})
        tail = self.owner.invoke("t1", target={"handle": handle}, name="tail")
        self.assertIn("read-echo", tail["value"])
        self.owner.expect_no_call("jobs.completed")

    def test_output_read_retires_a_pending_notice(self):
        handle = self.start_job("echo output-echo")
        job_id = self.wait_job_done()["id"]
        frame = self.owner.wait_for(lambda f: f.get("type") == "call")
        self.owner.send({"type": "reply", "id": frame["id"],
                         "value": {"ok": False, "code": "busy", "message": "session is busy"}})
        read = self.owner.invoke("o1", name="output.read", args=[job_id])
        self.assertIn("output-echo", read["value"])
        self.owner.expect_no_call("jobs.completed")

    def test_a_stopped_job_wakes_no_one(self):
        handle = self.start_job("sleep 5")
        stopped = self.owner.invoke("s1", target={"handle": handle}, name="stop")
        self.assertTrue(stopped["ok"])
        self.owner.expect_no_call("jobs.completed", window=1.5)

    def test_the_remote_stamp_names_the_host(self):
        owner = Owner(["bash"], env={"ALBEDO_REMOTE_TARGET": "trimounts"})
        self.addCleanup(owner.close)
        self.assertEqual(owner.wait_for(lambda f: f.get("type") == "ready")["type"], "ready")
        reply = owner.invoke("j1", name="bash", args=["echo remote-echo"])
        start = owner.wait_for(lambda f: f.get("type") == "job_start")
        owner.wait_for(lambda f: f.get("type") == "job" and f.get("id") == start["id"])
        frame = owner.wait_for(lambda f: f.get("type") == "call")
        args = frame["args"]
        self.assertEqual(args["host"], "trimounts")
        self.assertIn(" on trimounts", args["display"])
        owner.send({"type": "reply", "id": frame["id"],
                    "value": {"ok": True, "value": "delivered"}})


if __name__ == "__main__":
    unittest.main()
