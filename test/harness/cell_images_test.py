"""Catch retained image leaks and premature release during nested delivery.

The daemon cannot inspect archived captures or pause/refuse cells.finish, so
these checks use the real kernel through the shared owner channel.
"""

import unittest

from remote_kernel_test import OwnerChannel

PNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"
IMAGE = f"show_image(__import__('base64').b64decode({PNG!r}))\n"
INSPECT = """
import __main__ as kernel

def capture_state(id):
    capture = kernel.ARCHIVES[id]
    return {'images': len(capture.images), 'text': output.read(id)}

def finished_images():
    return {id: len(done['images']) for id, done in kernel.FINISHED.items()}
"""


class CellImagesTest(unittest.TestCase):
    def setUp(self):
        self.channel = OwnerChannel([])
        self.addCleanup(self.channel.close)
        self.assertEqual(self.channel.recv()["type"], "ready")
        self.execute("setup", INSPECT)

    def execute(self, id, code):
        self.channel.send({"type": "execute", "id": id, "code": code})
        return self.channel.wait_for(
            lambda frame: frame["type"] == "done" and frame["id"] == id
        )

    def state(self, id):
        reply = self.channel.invoke("inspect-" + id, name="capture_state", args=[id])
        self.assertTrue(reply["ok"])
        return reply["value"]

    def acknowledge(self, call, value=None, refused=False):
        answer = (
            {"ok": False, "code": "refused", "message": "finish refused"}
            if refused
            else {"ok": True, "value": value}
        )
        self.channel.send({"type": "reply", "id": call["id"], "value": answer})

    def finish_call(self):
        started = self.channel.wait_for(
            lambda frame: frame.get("method") == "cells.started"
        )
        self.acknowledge(started)
        return self.channel.wait_for(
            lambda frame: frame.get("method") == "cells.finish"
        )

    def test_delivered_success_error_and_cancellation_release_images(self):
        for status, ending in (
            ("ok", ""),
            ("error", "raise ValueError('execution failed')"),
            ("interrupted", "raise __import__('asyncio').CancelledError()"),
        ):
            with self.subTest(status=status):
                done = self.execute(status, IMAGE + "print('retained text')\n" + ending)
                self.assertEqual(done["status"], status)
                self.assertEqual(done["images"], [PNG])
                state = self.state(status)
                self.assertEqual(state["images"], 0)
                self.assertIn("retained text", state["text"])

    def test_nested_images_wait_for_acknowledgement_and_survive_refusal(self):
        for refused in (False, True):
            with self.subTest(refused=refused):
                child = f"child-{refused}"
                parent = "parent-" + child
                self.channel.send(
                    {
                        "type": "execute",
                        "id": parent,
                        "code": "await cells.run('saved')",
                    }
                )
                prepare = self.channel.wait_for(
                    lambda frame: frame.get("method") == "cells.prepare"
                )
                self.acknowledge(
                    prepare,
                    {"id": child, "source": IMAGE + "raise ValueError('child failed')"},
                )
                finish = self.finish_call()
                self.assertEqual(finish["args"]["outcome"]["status"], "error")
                self.assertEqual(finish["args"]["outcome"]["images"], [PNG])
                self.assertEqual(self.state(child)["images"], 1)
                self.assertEqual(self.state(parent)["images"], 1)
                self.acknowledge(finish, refused=refused)
                done = self.channel.wait_for(
                    lambda frame: frame["type"] == "done" and frame["id"] == parent
                )
                self.assertEqual(done["images"], [PNG])
                self.assertEqual(self.state(child)["images"], int(refused))
                self.assertEqual(self.state(parent)["images"], 0)

    def test_replays_keep_images_within_a_budget_newest_first(self):
        self.execute("budget", f"kernel.FINISHED_IMAGE_BYTES = {len(PNG) * 2}")
        for id in ("first", "second", "third"):
            self.assertEqual(self.execute(id, IMAGE)["images"], [PNG])
        reply = self.channel.invoke("finished", name="finished_images")
        self.assertEqual(
            {id: reply["value"][id] for id in ("first", "second", "third")},
            {"first": 0, "second": 1, "third": 1},
        )
        self.channel.send({"type": "execute", "id": "first", "code": "unused"})
        replayed = self.channel.wait_for(
            lambda frame: frame["type"] == "done" and frame["id"] == "first"
        )
        self.assertEqual(replayed["images"], [])
        self.assertIn("1 image(s) not kept for a replayed result", replayed["output"])
        self.assertIn("attached image/png", replayed["value"])


if __name__ == "__main__":
    unittest.main()
