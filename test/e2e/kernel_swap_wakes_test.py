"""A pending cell-completion wake must survive the idle swap of a stale kernel.

The incident behind this suite: a session ran a long background cell on a
kernel left stale by a daemon restart. At the turn's end a park nobody kept
asked for a kernel, so the runtime started the swap; the arriving replacement
was dropped with no notice, the old kernel (still holding the cell's pending
completion wake) was stopped, and the model was never told anything. The wake
must instead be admitted before the swap, ride it, and carry the upgrade
notice; a swap that does end a running cell must journal it interrupted and
say so.
"""

import json
import os
from pathlib import Path
import time
import unittest

import harness
from harness import Provider, exclusive, python, text
from kernel_upgrade_test import MARKER, editable_daemon


def user_text(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["input"])
            if item.get("role") == "user"
        ),
        "",
    )


# exclusive: boots an editable python bundle and restarts the daemon
@exclusive
class SwapWakeTests(unittest.TestCase):
    bundle: Path

    def setUp(self):
        self.cells = []

        def script(request):
            user = user_text(request)
            if "background python cells finished" in user:
                return text("wake seen")
            if user.endswith("hold"):
                return text("holding", delay=4.0)
            if request["input"][-1].get("role") == "user" and self.cells:
                return python(self.cells.pop(0))
            return text("ok")

        def prepare(app):
            launcher, self.bundle = editable_daemon(app.root)
            app.env["ALBEDO_DAEMON"] = str(launcher)
            app.env["ALBEDO_CELL_BACKGROUND_SECONDS"] = "0.5"

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = harness.Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def cell(self, code):
        """Run one cell through a model turn; its result and the turn's prompt."""
        self.cells.append(code)
        self.app.prompt(self.session, "run it").close()
        self.app.idle(self.session)
        results = [
            json.loads(part["value"])
            for entry in self.app.history(self.session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        ]
        request = next(
            r["request"]
            for r in reversed(self.provider.requests)
            if any(i.get("role") == "user" for i in r["request"]["input"])
        )
        prompt = [i["content"] for i in request["input"] if i.get("role") == "user"][-1]
        return results[-1], prompt

    def kernel(self):
        with self.app.api(f"/sessions/{self.session}?tail=0") as response:
            return json.load(response)["kernel"]

    def gate(self):
        gate = self.app.workspace / "cell-gate"
        os.mkfifo(gate)
        self.addCleanup(harness.release_fifo, gate)
        return gate

    def held_cell(self, *, protocol_skew=False):
        """Cell code whose backgrounded job runs until the gate is released:
        the cell finishes only when the test decides, like the incident's
        build, and the kernel's loop stays free to answer the daemon."""
        gate = self.gate()
        program = f"open({str(gate)!r}, 'rb').read(1)"
        prefix = (
            "import albedo_link, os, sys\nalbedo_link.PROTOCOL = 2\n"
            if protocol_skew
            else "import os, sys\n"
        )
        code = (
            f"{prefix}survivor = 41\n"
            f"j = run(sys.executable, '-c', {program!r})\n"
            "await j\n('gate done',)"
        )
        return gate, code

    def wait_for_wake(self):
        deadline = time.monotonic() + 40
        while time.monotonic() < deadline:
            for record in reversed(self.provider.requests):
                if "background python cells finished" in user_text(record["request"]):
                    return user_text(record["request"])
            time.sleep(0.1)
        self.fail("the cell completion wake never reached the model")

    def test_a_pending_cell_wake_survives_the_idle_kernel_swap(self):
        gate, code = self.held_cell()
        first, _ = self.cell(code)
        self.assertEqual(first["status"], "backgrounded", first)

        with (self.bundle / "albedo_bundle.py").open("a") as source:
            source.write(MARKER)
        self.app.restart()

        # One slow turn on the still-stale kernel (its live job holds the
        # swap). The gate is released mid-turn, so the background cell
        # finishes and its wake retries while the session is busy, exactly as
        # in the incident; the spurious park used to fire when this turn
        # ended, starting a swap that killed the wake with the old kernel.
        self.app.prompt(self.session, "hold").close()
        time.sleep(0.8)
        harness.wait_until(
            lambda: harness.release_fifo(gate), 10, "the held job never opened its gate"
        )
        self.app.idle(self.session)

        wake = self.wait_for_wake()
        self.app.idle(self.session)
        # The wake was admitted before the swap, so it rides the swapped
        # kernel's turn together with the upgrade notice.
        self.assertIn("The python kernel was upgraded to the new python bundle", wake)
        self.assertRegex(wake, r"Restored: [^.]*\bsurvivor\b")

        swapped, _ = self.cell(
            "import albedo_bundle, os\n"
            "(survivor, getattr(albedo_bundle, 'MARKER', None), os.getpid())"
        )
        self.assertEqual(swapped.get("status"), "ok", swapped)
        survivor, marker, _pid = swapped["value"].strip("()").split(", ")
        self.assertEqual((survivor, marker), ("41", "'new bundle'"), swapped)
        self.assertFalse(self.kernel()["stale"])

    def test_a_swap_past_a_running_cell_ends_it_as_interrupted(self):
        # A kernel on another protocol is swapped regardless of live work, so
        # the swap ends the running cell: it must be journaled interrupted and
        # named, not left `started` with its effects unknown. (The explicit
        # upgrade refuses while a cell runs: "a cell is still running".)
        gate, code = self.held_cell(protocol_skew=True)
        first, _ = self.cell(code)
        self.assertEqual(first["status"], "backgrounded", first)
        cell_id = first["cell_id"]

        self.app.restart()
        ended, prompt = self.cell(f"print(await cells.info({cell_id!r}))")
        self.assertIn("'status': 'interrupted'", ended["output"], ended)
        self.assertIn(
            "The python kernel was upgraded to the current kernel protocol", prompt
        )
        self.assertIn(f"Cells ended by the swap: {cell_id}", prompt)


if __name__ == "__main__":
    unittest.main()
