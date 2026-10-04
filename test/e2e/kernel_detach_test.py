"""A session's kernel outlives its daemon and its bridge.

The kernel runs detached behind a bridge process; the daemon reattaches to it
after a restart (graceful or crash) and after the bridge dies mid-cell, so the
namespace, the kernel process, and an in-flight cell's result all survive.
A kernel found dead after a restart has its jobs ended.
"""

import ast
import json
import os
import signal
import subprocess
import time
import unittest

from harness import alive
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


# exclusive: restarts the daemon
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
            json.loads(part["value"])
            for entry in self.app.history(self.session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
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
            part["text"]
            for entry in self.app.history(self.session)["items"]
            if entry["kind"] == "note"
            for part in entry["content"]
            if part["kind"] == "text"
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

    def test_concurrent_jobs_keep_running_and_deadlines_count_wall_time(self):
        # Legacy admission settings must not throttle new kernels.
        self.app.daemon.env.update(
            ALBEDO_MAX_LOCAL_JOBS="1", ALBEDO_JOB_GRACE_SECONDS="0.2"
        )
        self.app.restart()
        program = "import time; time.sleep(5.5); print('progress', flush=True); time.sleep(60)"
        result = self.cell(
            "import sys\n"
            f"workers = [run(sys.executable, '-c', {program!r}, timeout=7) for _ in range(3)]\n"
            "for worker in workers:\n    await worker\n"
            "[(worker.timed_out, worker.duration, worker.tail().startswith('progress')) for worker in workers]"
        )
        self.assertEqual(result["status"], "ok", result)
        outcomes = ast.literal_eval(result["value"])
        self.assertEqual(len(outcomes), 3)
        for timed_out, duration, progressed in outcomes:
            self.assertTrue(timed_out)
            self.assertTrue(progressed)
            self.assertGreaterEqual(duration, 7)
            self.assertLess(duration, 10)

    def test_a_kernel_killed_while_the_daemon_was_down_has_its_jobs_ended(self):
        started = self.cell(
            "import asyncio, os\nj = run('sleep', '300')\nawait asyncio.sleep(0.5)\n(os.getpid(), j.process.pid)"
        )
        kernel, job = (int(part) for part in started["value"].strip("()").split(","))

        # Graceful stop leaves the kernel running; it dies hard before the
        # next daemon reaches it, and its job's group outlives it.
        self.app.restart(prepare=lambda _: os.kill(kernel, signal.SIGKILL))
        deadline = time.monotonic() + 15
        while alive(job) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(alive(job), "the dead kernel's job is still running")


if __name__ == "__main__":
    unittest.main()
