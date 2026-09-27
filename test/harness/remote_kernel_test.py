"""The remote control-frame protocol must preserve pending call races, live references and typed values without requiring an SSH server."""
import asyncio
import json
import os
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


class OwnerChannel:
    """A minimal owner: speak the kernel's control frames over stdio.

    Frames the owner is not looking for stay buffered, so looking for one kind
    never discards another (mirrors and job events interleave with replies).
    """

    def __init__(self, modules):
        self.workspace = tempfile.mkdtemp(prefix="albedo-owner-")
        self.process = subprocess.Popen(
            [sys.executable, "-u", str(KERNEL), json.dumps(modules)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=self.workspace)
        self.buffered = []

    def close(self):
        self.send({"type": "shutdown"})
        self.process.wait(timeout=10)
        self.process.stdin.close()
        self.process.stdout.close()
        self.process.stderr.close()
        self.buffered.clear()

    def send(self, message):
        data = json.dumps(message).encode()
        self.process.stdin.write(struct.pack(">I", len(data)) + data)
        self.process.stdin.flush()

    def recv(self):
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
            self.buffered.append(self.recv())
        raise AssertionError(f"no matching frame; buffered: "
                             f"{[f.get('type') for f in self.buffered]}")

    def recv_reply(self, call_id):
        return self.wait_for(
            lambda f: f.get("id") == call_id and f["type"] in ("invoked", "introspected"))

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


    def test_pending_targets_resolve_calls_raced_ahead_of_their_reply(self):
        self.channel.send({"type": "invoke", "id": "r1", "name": "run", "args": python(
            "import time; print('raced', flush=True); time.sleep(0.3); print('done')")})
        # tail() is called before the run reply can exist; the pending target waits
        raced = self.channel.invoke("r2", target={"pending": "r1"}, name="tail")
        self.assertTrue(raced["ok"])
        self.assertEqual(raced["value"], "")
        reply = self.channel.recv_reply("r1")
        self.assertTrue(reply["ok"])
        done = self.channel.invoke("r3", target={"handle": reply["handle"]}, **{"await": True})
        self.assertEqual(done["state"]["tail"], "raced\ndone\n")


    def test_a_failing_pending_call_propagates_its_error(self):
        self.channel.send({"type": "invoke", "id": "f1", "name": "nope"})
        failure = self.channel.invoke("f2", target={"pending": "f1"}, name="tail")
        self.assertFalse(failure["ok"])
        self.assertEqual(failure["error"]["ename"], "LookupError")

    def test_typed_composites_carry_a_reference_and_their_value(self):
        Path(self.channel.workspace, "note.txt").write_text("needle one\nplain\nneedle two\n")
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
        bad = self.channel.invoke("i2", name="files.read", args=[{"__ref__": "not-a-handle"}])
        self.assertFalse(bad["ok"])
        self.assertEqual(bad["error"]["ename"], "LookupError")
        # A live reference resolves to the object itself; the failure that follows
        # is the call's own, proving the marker never leaked through as a dict.
        answered = self.channel.invoke("i3", name="files.read", args=[{"__ref__": handle}])
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
