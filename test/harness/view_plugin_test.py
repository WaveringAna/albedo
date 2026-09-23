"""The view plugin: albedo-render pages attached to the running cell."""
import asyncio
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
from albedo_api import PythonApi
from albedo_plugins import files, view as plugin


class FakeJob:
    def __init__(self, output, exit_code):
        self.output, self.exit_code, self.timed_out = output, exit_code, False

    def __await__(self):
        async def settled():
            return self
        return settled().__await__()

    def tail(self, _limit):
        return self.output


def real_bash(command, timeout):
    """What `bash(command)` would run, executed here without a kernel."""
    done = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=timeout)
    return FakeJob(done.stdout + done.stderr, done.returncode)


class ViewPluginTest(unittest.TestCase):
    def setUp(self):
        self.loop = asyncio.new_event_loop()
        self.addCleanup(self.loop.close)
        self.root = Path(tempfile.mkdtemp(prefix="albedo-view-test-"))

    def write(self, name, content):
        path = self.root/name
        path.write_text(content)
        return path

    def view_code(self, attach):
        api = PythonApi(self.loop, None, RuntimeError, None, 100, lambda event: None,
                        lambda close: None, lambda _: None, attach_image=attach)
        return plugin.setup(api)["view_code"]

    def run_view(self, attach, *args, **kwargs):
        with patch.object(files.jobs, "bash", real_bash), \
             patch.object(files.jobs, "forget", lambda job: None), \
             patch.object(files.jobs, "preview_limit", 65_536, create=True):
            return self.loop.run_until_complete(self.view_code(attach)(*args, **kwargs))

    @unittest.skipUnless(plugin.RENDERER.exists(), "albedo-render is not built")
    def test_pages_attach_in_order_and_the_text_names_the_rest(self):
        path = self.write("app.py", "".join(f"value_{n} = {n}\n" for n in range(1, 401)))
        attached = []
        text = self.run_view(lambda data: attached.append(data) or "attached", str(path), 11)
        self.assertEqual(len(attached), 4)
        self.assertTrue(all(data.startswith(b"\x89PNG\r\n\x1a\n") for data in attached))
        lines = text.splitlines()
        self.assertEqual(lines[0], f"{path} (python)")
        # 390 lines need 5 pages of at most 80; each holds 78.
        self.assertRegex(lines[1], r"^image 1: lines 11-88, \d+x\d+$")
        self.assertRegex(lines[4], r"^image 4: lines 245-322, ")
        self.assertEqual(lines[5], f"not shown from line 323: view_code({str(path)!r}, 323)")

    @unittest.skipUnless(plugin.RENDERER.exists(), "albedo-render is not built")
    def test_the_cell_image_limit_and_bad_requests_are_explained(self):
        path = self.write("a.rs", "".join(f"let x{n} = {n};\n" for n in range(1, 201)))
        taken = []

        def one_only(data):
            if taken:
                raise ValueError("a cell returns at most 4 images")
            taken.append(data)
            return "attached"

        lines = self.run_view(one_only, str(path), 1, 200).splitlines()
        self.assertRegex(lines[1], r"^image 1: lines 1-67, \d+x\d+$")
        self.assertEqual(lines[2:], [
            "image 2 not attached: a cell returns at most 4 images",
            f"not shown from line 68: view_code({str(path)!r}, 68)",
        ])
        with self.assertRaisesRegex(RuntimeError, "has 200 lines; --start 300 is past the end"):
            self.run_view(one_only, str(path), 300)
        with self.assertRaisesRegex(FileNotFoundError, "nearby paths: .*a.rs"):
            self.run_view(one_only, str(self.root/"b.rs"))

    def test_it_says_how_to_get_it_when_it_cannot_run(self):
        path = self.write("a.py", "x = 1\n")
        with self.assertRaisesRegex(RuntimeError, "cannot return images"):
            self.run_view(None, str(path))
        with patch.object(plugin, "RENDERER", self.root/"missing"), \
             patch.object(plugin, "_which", lambda name: None), \
             self.assertRaisesRegex(RuntimeError, "native/render/install.sh"):
            self.run_view(lambda data: "attached", str(path))
        self.assertEqual(repr(self.view_code(None)(str(path))),
                         "<view_code(...) has not run: use `await view_code(...)` for its images>")
        with self.assertRaisesRegex(ValueError, "end_line >= start_line"):
            self.view_code(None)(str(path), 5, 4)


if __name__ == "__main__":
    unittest.main()
