"""File trace distinguishes user edits from process supervision and atomic temporaries."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_trace


class Capture:
    def __init__(self):
        self.trace = albedo_trace.Trace()


class TraceTest(unittest.TestCase):
    def test_atomic_replace_records_destination_without_temp_and_ignores_proc(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory) / "file.py"
            temporary = Path(directory) / ".file.py.tmp"
            target.write_text("old\n")
            capture = Capture()
            albedo_trace.install(lambda: capture)
            # The audit hook observes only this capture; imports and cleanup run outside it.
            try:
                with open("/proc/46202/stat", "rb"):
                    pass
            except OSError:
                pass
            try:
                os.listdir("/proc")
            except OSError:
                pass
            self.assertEqual(target.read_text(), "old\n")
            temporary.write_text("new\n")
            os.replace(temporary, target)
            trace = capture.trace.finish()
            self.assertEqual([item["target"] for item in trace["activities"]], [str(target)])
            self.assertEqual([change["path"] for change in trace["changes"]], [str(target)])
            self.assertEqual(trace["changes"][0]["kind"], "diff")
            self.assertEqual(trace["changes"][0]["added"], 1)


if __name__ == "__main__":
    unittest.main()
