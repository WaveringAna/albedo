"""Binary pipe boundaries and early reader closure are race-prone kernel behavior the daemon E2E suite cannot drive reliably."""

from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from job_wake_test import Owner  # noqa: E402


class RunTest(unittest.TestCase):
    def setUp(self):
        self.owner = Owner(["run"])
        self.addCleanup(self.owner.close)
        self.owner.wait_for(lambda f: f.get("type") == "ready")
        self.cells = 0

    def cell(self, code):
        self.cells += 1
        id = f"c{self.cells}"
        self.owner.send({"type": "execute", "id": id, "code": code})
        done = self.owner.wait_for(
            lambda f: f.get("type") == "done" and f.get("id") == id
        )
        return done

    def test_a_pipe_carries_bytes_exactly_and_past_the_retention_cap(self):
        done = self.cell(
            "import hashlib, sys\n"
            "blob = bytes(range(256)) * 20000\n"
            "writer = run(sys.executable, '-c', 'import sys; sys.stdout.buffer.write(bytes(range(256)) * 20000)')\n"
            "reader = await writer.pipe(sys.executable, '-c', 'import hashlib, sys; "
            "print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')\n"
            "reader.tail().strip() == hashlib.sha256(blob).hexdigest()"
        )
        self.assertEqual(done["value"], "True")

    def test_late_pipe_preserves_non_utf8_bytes(self):
        done = self.cell(
            "import sys\n"
            "writer = run(sys.executable, '-c', 'import sys; sys.stdout.buffer.write(bytes([0, 255, 254, 10]))')\n"
            "await writer\n"
            "reader = await run(sys.executable, '-c', 'import sys; print(list(sys.stdin.buffer.read()))', stdin=writer)\n"
            "reader.tail().strip()"
        )
        self.assertEqual(done["value"], "'[0, 255, 254, 10]'")

    def test_a_reader_that_stops_ends_the_writer(self):
        done = self.cell(
            "import asyncio\nwriter = run('yes')\nreader = await writer.pipe('head', '-2')\n"
            "await asyncio.wait_for(asyncio.shield(writer.task), 5)\n"
            "(reader.tail(), writer.exit_code != 0)"
        )
        self.assertEqual(done["value"], "('y\\ny\\n', True)")

    def test_a_finished_job_feeds_what_it_retained(self):
        done = self.cell(
            "out = await run('printf', 'x\\ny\\n')\n(await run('wc', '-l', stdin=out)).tail().strip()"
        )
        self.assertEqual(done["value"], "'2'")
        done = self.cell(
            "import sys\nbig = await run(sys.executable, '-c', 'print(\"x\" * 2000000)')\n"
            "run('wc', '-c', stdin=big)"
        )
        self.assertIn("pipe from it before it runs", done["output"])


if __name__ == "__main__":
    unittest.main()
