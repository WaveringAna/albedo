"""Exercise owner frames the daemon cannot generate, including malformed messages.

The real kernel must clean up children on invalid input while preserving pending
call races, live references and typed values without an SSH server.
"""

import json
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


class OwnerChannel:
    """A minimal owner: speak the kernel's control frames over stdio.

    Frames the owner is not looking for stay buffered, so looking for one kind
    never discards another (mirrors and job events interleave with replies).
    """

    def __init__(self, modules):
        self.workspace = tempfile.mkdtemp(prefix="albedo-owner-")
        self.process = subprocess.Popen(
            [sys.executable, "-u", str(KERNEL), json.dumps(modules)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
            cwd=self.workspace,
        )
        self.buffered = []

    def close(self):
        if self.process.poll() is None:
            self.send({"type": "shutdown"})
        self.process.wait(timeout=10)
        assert self.process.stdin is not None
        assert self.process.stdout is not None
        assert self.process.stderr is not None
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        self.buffered.clear()

    def send(self, message):
        data = json.dumps(message).encode()
        assert self.process.stdin is not None
        self.process.stdin.write(struct.pack(">I", len(data)) + data)
        self.process.stdin.flush()

    def recv(self):
        assert self.process.stdout is not None
        if not select.select([self.process.stdout], [], [], 10)[0]:
            raise AssertionError("kernel did not send a frame within 10 seconds")
        header = self.read_exact(4)
        size = struct.unpack(">I", header)[0]
        assert size <= MAX_FRAME, "control frame exceeds the ceiling"
        return json.loads(self.read_exact(size))

    def read_exact(self, size):
        assert self.process.stdout is not None
        data = bytearray()
        while len(data) < size:
            chunk = self.process.stdout.read(size - len(data))
            if not chunk:
                raise AssertionError("kernel closed the channel during a frame")
            data.extend(chunk)
        return bytes(data)

    def wait_for(self, predicate, timeout=10.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, frame in enumerate(self.buffered):
                if predicate(frame):
                    return self.buffered.pop(index)
            self.buffered.append(self.recv())
        raise AssertionError(
            f"no matching frame; buffered: {[f.get('type') for f in self.buffered]}"
        )

    def recv_reply(self, call_id):
        return self.wait_for(
            lambda f: (
                f.get("id") == call_id and f["type"] in ("invoked", "introspected")
            )
        )

    def invoke(self, call_id, **frame):
        self.send({"type": "invoke", "id": call_id, **frame})
        return self.recv_reply(call_id)


def python(source):
    """run() arguments for a few steps of Python in a child interpreter."""
    return [sys.executable, "-c", source]


class KernelInvokeTest(unittest.TestCase):
    def setUp(self):
        self.channel = OwnerChannel(["run", "files"])
        self.addCleanup(self.channel.close)
        ready = self.channel.recv()
        self.assertEqual(ready["type"], "ready")

    def test_malformed_frames_shutdown_and_clean_up_a_child(self):
        frames = [
            [],
            None,
            {},
            {"type": "unknown"},
            {"type": "execute", "id": "x"},
            {"type": "execute", "id": "x", "code": 7},
            {"type": "execute", "id": "x", "code": "", "durable": 1},
            {"type": "execute", "id": "x", "code": "", "max_edge": True},
            {"type": "invoke", "id": []},
            {"type": "invoke", "id": "x", "args": {}},
            {"type": "invoke", "id": "x", "kwargs": []},
            {"type": "invoke", "id": "x", "await": 1},
            {"type": "invoke", "id": "x", "target": {"handle": "a", "pending": "b"}},
            {"type": "invoke", "id": "x", "target": {"handle": 1}},
            {"type": "reply", "id": "x", "value": []},
            {"type": "reply", "id": "x", "value": {"ok": 1, "value": None}},
            {"type": "reply", "id": "x", "value": {"ok": True}},
            {"type": "reply", "id": "x", "value": {"ok": False, "code": "bad"}},
            {"type": "job_slot", "id": "x", "ok": "yes"},
            {"type": "interrupt", "id": "x", "reason": "other"},
            {"type": "restore", "id": "x", "path": None},
            {"type": "release", "handle": []},
        ]
        payloads = [json.dumps(frame).encode() for frame in frames] + [b"{bad json"]
        wire_frames = [struct.pack(">I", len(data)) + data for data in payloads]
        wire_frames.append(struct.pack(">I", MAX_FRAME + 1))
        for wire in wire_frames:
            with self.subTest(wire=wire[:160]):
                channel = OwnerChannel(["run"])
                try:
                    self.assertEqual(channel.recv()["type"], "ready")
                    channel.invoke(
                        "child", name="run", args=python("import time; time.sleep(60)")
                    )
                    started = channel.wait_for(
                        lambda frame: frame["type"] == "job_start"
                    )
                    assert channel.process.stdin is not None
                    channel.process.stdin.write(wire)
                    channel.process.stdin.flush()
                    channel.process.wait(timeout=5)
                    # Cleanup reaps the child before the kernel kills its own group.
                    self.assertFalse(Path(f"/proc/{started['pgid']}").exists())
                finally:
                    channel.close()

    def test_extra_fields_and_missing_methods_keep_the_channel_open(self):
        reply = self.channel.invoke(
            "extra", name="files.read", args=["missing"], extra=True
        )
        self.assertFalse(reply["ok"])
        self.assertFalse(self.channel.invoke("missing")["ok"])
        self.channel.send({"type": "introspect", "id": "still-open", "extra": []})
        self.assertIn("run", self.channel.recv_reply("still-open")["names"])

    def test_pending_targets_resolve_calls_raced_ahead_of_their_reply(self):
        self.channel.send(
            {
                "type": "invoke",
                "id": "r1",
                "name": "run",
                "args": python(
                    "import time; print('raced', flush=True); time.sleep(0.3); print('done')"
                ),
            }
        )
        # tail() is called before the run reply can exist; the pending target waits
        raced = self.channel.invoke("r2", target={"pending": "r1"}, name="tail")
        self.assertTrue(raced["ok"])
        self.assertEqual(raced["value"], "")
        reply = self.channel.recv_reply("r1")
        self.assertTrue(reply["ok"])
        done = self.channel.invoke(
            "r3", target={"handle": reply["handle"]}, **{"await": True}
        )
        self.assertEqual(done["state"]["tail"], "raced\ndone\n")

    def test_interrupt_cancels_an_await_without_losing_the_reference(self):
        reply = self.channel.invoke(
            "job",
            name="run",
            args=python("import time; time.sleep(1); print('finished')"),
        )
        handle = reply["handle"]
        self.channel.send(
            {
                "type": "invoke",
                "id": "wait",
                "target": {"handle": handle},
                "await": True,
            }
        )
        # A mirror arrives after the await task has had a loop turn to start.
        self.channel.wait_for(lambda frame: frame["type"] == "mirror")
        self.channel.send({"type": "interrupt", "id": "wait"})
        cancelled = self.channel.recv_reply("wait")
        self.assertFalse(cancelled["ok"])
        self.assertTrue(cancelled["cancelled"])
        finished = self.channel.invoke(
            "finish", target={"handle": handle}, **{"await": True}
        )
        self.assertTrue(finished["ok"])
        self.assertEqual(finished["state"]["tail"], "finished\n")

    def test_interrupt_for_a_queued_cell_lands_when_it_starts(self):
        self.channel.send(
            {"type": "execute", "id": "busy", "code": "import time; time.sleep(0.5)"}
        )
        self.channel.send({"type": "execute", "id": "queued", "code": "ran = True"})
        self.channel.send({"type": "interrupt", "id": "queued", "reason": "deadline"})
        busy = self.channel.wait_for(lambda f: f["type"] == "done")
        self.assertEqual((busy["id"], busy["status"]), ("busy", "ok"))
        queued = self.channel.wait_for(lambda f: f["type"] == "done")
        self.assertEqual((queued["id"], queued["status"]), ("queued", "interrupted"))
        self.assertIn("deadline exceeded", queued["output"])
        self.channel.send({"type": "execute", "id": "check", "code": "'ran' in dir()"})
        check = self.channel.wait_for(lambda f: f["type"] == "done")
        self.assertEqual(check["value"], "False")

    def test_a_failing_pending_call_propagates_its_error(self):
        self.channel.send({"type": "invoke", "id": "f1", "name": "nope"})
        failure = self.channel.invoke("f2", target={"pending": "f1"}, name="tail")
        self.assertFalse(failure["ok"])
        self.assertEqual(failure["error"]["ename"], "LookupError")

    def test_typed_composites_carry_a_reference_and_their_value(self):
        Path(self.channel.workspace, "note.txt").write_text(
            "needle one\nplain\nneedle two\n"
        )
        reply = self.channel.invoke("i1", name="files.find", args=["needle", "."])
        self.assertTrue(reply["ok"])
        self.assertIn("handle", reply)
        value = reply["value"]
        self.assertEqual(value["__list__"], "albedo_plugins.files.Rows")
        self.assertEqual(value["items"][0]["__class__"], "albedo_plugins.files.Match")
        self.assertEqual(value["items"][0]["fields"]["line"], 1)
        self.assertEqual(len(value["items"]), 2)

    def test_reference_arguments_resolve_back_to_live_objects(self):
        reply = self.channel.invoke("i1", name="run", args=["echo", "ref-roundtrip"])
        handle = reply["handle"]
        bad = self.channel.invoke(
            "i2", name="files.read", args=[{"__ref__": "not-a-handle"}]
        )
        self.assertFalse(bad["ok"])
        self.assertEqual(bad["error"]["ename"], "LookupError")
        # A live reference resolves to the object itself; the failure that follows
        # is the call's own, proving the marker never leaked through as a dict.
        answered = self.channel.invoke(
            "i3", name="files.read", args=[{"__ref__": handle}]
        )
        self.assertFalse(answered["ok"])
        self.assertNotEqual(answered["error"]["ename"], "LookupError")

    def test_release_forgets_the_reference(self):
        reply = self.channel.invoke("i1", name="run", args=["true"])
        handle = reply["handle"]
        self.channel.send({"type": "release", "handle": handle})
        gone = self.channel.invoke("i2", target={"handle": handle}, name="poll")
        self.assertFalse(gone["ok"])


if __name__ == "__main__":
    unittest.main()
