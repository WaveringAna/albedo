"""File trace distinguishes user edits from process supervision and atomic temporaries."""
import os
from pathlib import Path
import shutil
import subprocess
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

    def test_run_shows_the_command_without_shell_or_store_prefix(self):
        capture = Capture()
        albedo_trace.install(lambda: capture)
        subprocess.run("true 'shell form'", shell=True, check=True)
        subprocess.run([shutil.which("true"), "a b"], check=True)
        with albedo_trace.unobserved():
            subprocess.run(["true", "harness plumbing"], check=True)
        albedo_trace.note("run", "echo asked")
        trace = capture.trace.finish()
        self.assertEqual([item["target"] for item in trace["activities"] if item["kind"] == "run"],
                         ["true 'shell form'", "true 'a b'", "echo asked"])

    def test_command_keeps_relative_programs_and_odd_argv(self):
        self.assertEqual(albedo_trace.command(["./build/tool", "-v"]), "./build/tool -v")
        self.assertEqual(albedo_trace.command([b"/bin/zsh", b"-c", b"ls | wc"]), "ls | wc")
        self.assertEqual(albedo_trace.command(["/bin/sh", "-e", "-c", "x"]), "x")
        self.assertEqual(albedo_trace.command("plain string"), "plain string")
        self.assertEqual(albedo_trace.command([]), "")


if __name__ == "__main__":
    unittest.main()
