"""A session's kernel outlives its daemon and its bridge.

The kernel runs detached behind a bridge process; the daemon reattaches to it
after a restart (graceful or crash) and after the bridge dies mid-cell, so the
namespace, the kernel process, and an in-flight cell's result all survive.
"""

import json
import os
import signal
import subprocess
import time
import unittest

from harness import Albedo, Provider, exclusive, python, text


def bridges(home):
    """Pids of the bridges whose kernel lives under this daemon's home."""
    listing = subprocess.run(
        ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
    ).stdout
    return [
        int(line.split(None, 1)[0])
        for line in listing.splitlines()
        if "albedo_bridge.py" in line and str(home) in line
    ]


@exclusive
class KernelDetachTests(unittest.TestCase):
    def setUp(self):
        self.cells = []

        def script(request):
            if request["input"][-1].get("role") == "user" and self.cells:
                return python(self.cells.pop(0))
            return text("ok")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def cell(self, code, *, during=None):
        """Run one cell through a model turn and return its tool result."""
        self.cells.append(code)
        self.app.prompt(self.session, "run it").close()
        if during:
            during()
        self.app.idle(self.session)
        results = [
            json.loads(event["result"])
            for event in self.app.events(self.session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ]
        return results[-1]

    def test_variables_survive_graceful_and_crash_restarts(self):
        first = self.cell("import os\nsurvivor = 41\nos.getpid()")
        self.app.restart()
        after_stop = self.cell("survivor += 1\n(survivor, os.getpid())")
        self.assertEqual(after_stop["value"], f"(42, {first['value']})")
        self.app.restart(crash=True)
        after_crash = self.cell("survivor += 1\n(survivor, os.getpid())")
        self.assertEqual(after_crash["value"], f"(43, {first['value']})")
        notes = [
            event["text"]
            for event in self.app.events(self.session)
            if event.get("type") == "note"
        ]
        self.assertFalse([note for note in notes if "variables are gone" in note])

    def test_a_bridge_killed_mid_cell_still_delivers_the_result(self):
        first = self.cell("import os\nos.getpid()")
        (bridge,) = bridges(self.app.home)

        def kill_bridge():
            time.sleep(1)
            os.kill(bridge, signal.SIGKILL)

        slept = self.cell(
            "import time\ntime.sleep(3)\nprint('woke')\nos.getpid()",
            during=kill_bridge,
        )
        self.assertEqual(slept["status"], "ok", slept)
        self.assertEqual(slept["output"].strip(), "woke")
        self.assertEqual(slept["value"], first["value"])
        (replacement,) = bridges(self.app.home)
        self.assertNotEqual(replacement, bridge)


if __name__ == "__main__":
    unittest.main()
