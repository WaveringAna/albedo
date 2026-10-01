"""Catch premature trace release and observation after nested execution.

The daemon cannot refuse trace writes or gate cells.finish acknowledgements,
so these checks drive the real kernel through its owner channel.
"""

import unittest

from remote_kernel_test import OwnerChannel

INSPECT = """
import __main__ as kernel
import asyncio, sys

def trace_state(id):
    trace = kernel.ARCHIVES[id].trace
    return {'sealed': trace.sealed, 'before': len(trace.before),
            'activities': len(trace.activities), 'truncated': trace.truncated}

async def release_late():
    late_gate.set()
    await late_task
    return trace_state('child')
"""
EDIT = "open('note.txt', 'w').write('edited\\n')\nopen('note.txt').read()\n"


class CellTracesTest(unittest.TestCase):
    def setUp(self):
        self.channel = OwnerChannel([])
        self.addCleanup(self.channel.close)
        self.assertEqual(self.channel.recv()["type"], "ready")
        self.execute("setup", INSPECT)

    def execute(self, id, code):
        self.channel.send({"type": "execute", "id": id, "code": code})
        trace = self.channel.wait_for(
            lambda frame: frame["type"] == "trace" and frame["id"] == id
        )
        self.assertFalse(
            any(
                frame["type"] == "done" and frame["id"] == id
                for frame in self.channel.buffered
            )
        )
        done = self.channel.wait_for(
            lambda frame: frame["type"] == "done" and frame["id"] == id
        )
        return trace["trace"], done

    def state(self, id):
        reply = self.channel.invoke("inspect-" + id, name="trace_state", args=[id])
        self.assertTrue(reply["ok"], reply)
        return reply["value"]

    def acknowledge(self, call, value=None):
        self.channel.send(
            {"type": "reply", "id": call["id"], "value": {"ok": True, "value": value}}
        )

    def test_nested_seals_before_ack_and_late_task_cannot_refill(self):
        self.channel.send(
            {"type": "execute", "id": "parent", "code": "await cells.run('saved')"}
        )
        prepare = self.channel.wait_for(
            lambda frame: frame.get("method") == "cells.prepare"
        )
        self.acknowledge(
            prepare,
            {
                "id": "child",
                "source": EDIT
                + """
late_gate = asyncio.Event()
async def late_edit():
    await late_gate.wait()
    open('note.txt', 'w').write('late\\n')
    sys.audit('open')
    kernel.albedo_trace.note('read', 'late')
late_task = asyncio.create_task(late_edit())
""",
            },
        )
        started = self.channel.wait_for(
            lambda frame: frame.get("method") == "cells.started"
        )
        self.acknowledge(started)
        frame = self.channel.wait_for(
            lambda frame: frame["type"] == "trace" and frame["id"] == "child"
        )
        self.assertFalse(
            any(
                frame.get("method") == "cells.finish" for frame in self.channel.buffered
            )
        )
        finish = self.channel.wait_for(
            lambda frame: frame.get("method") == "cells.finish"
        )
        expected = {"sealed": True, "before": 0, "activities": 0, "truncated": False}
        self.assertEqual(self.state("child"), expected)
        reply = self.channel.invoke("late", name="release_late")
        self.assertTrue(reply["ok"], reply)
        self.assertEqual(reply["value"], expected)
        self.assertIn("+edited", frame["trace"]["changes"][0]["diff"])
        self.acknowledge(finish)
        self.channel.wait_for(
            lambda frame: frame["type"] == "done" and frame["id"] == "parent"
        )
        self.assertEqual(self.state("child"), expected)

    def test_delivery_failure_keeps_sealed_buffers_and_propagates(self):
        _, done = self.execute(
            "failures",
            """
def fail_delivery(finalization=False):
    capture = kernel.Capture('undelivered')
    capture.trace.writing('missing.txt')
    capture.trace.activity('read', 'missing.txt')
    original_send = kernel.send
    original_snapshot = kernel.albedo_trace.snapshot
    def fail(*args):
        raise OSError('forced failure')
    try:
        if finalization:
            kernel.albedo_trace.snapshot = fail
        else:
            kernel.send = fail
        try:
            kernel.deliver_trace(capture)
        except OSError:
            pass
        else:
            raise AssertionError('failure did not propagate')
    finally:
        kernel.send = original_send
        kernel.albedo_trace.snapshot = original_snapshot
    trace = capture.trace
    assert trace.sealed and trace.before and trace.activities
    trace.writing('late.txt')
    trace.activity('read', 'late.txt')
    trace.renamed('missing.txt', 'late.txt')
    assert len(trace.before) == len(trace.activities) == 1
    try:
        trace.finish()
    except RuntimeError:
        pass
    else:
        raise AssertionError('finish allowed twice')
fail_delivery()
fail_delivery(True)
""",
        )
        self.assertEqual(done["status"], "ok", done)

    def test_payload_is_detached_and_release_is_idempotent(self):
        _, done = self.execute(
            "detached",
            """
trace = kernel.albedo_trace.Trace()
try:
    trace.release()
except RuntimeError:
    pass
else:
    raise AssertionError('released an observing trace')
trace.truncated = True
trace.activity('read', 'original')
trace.writing('missing.txt')
payload = trace.finish()
trace.activities[('read', 'original')]['target'] = 'mutated'
trace.release()
trace.release()
assert payload['activities'] == [{'kind': 'read', 'target': 'original'}]
assert not trace.before and not trace.activities
assert payload['truncated'] and trace.truncated
""",
        )
        self.assertEqual(done["status"], "ok", done)


if __name__ == "__main__":
    unittest.main()
