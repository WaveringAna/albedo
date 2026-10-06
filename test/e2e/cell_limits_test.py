"""A cell's output past the preview is spilled whole to a file, and a cell that
pushes the kernel past its memory cap is interrupted while the namespace lives on."""

import json
import os
import unittest

from harness import Albedo, Provider, exclusive, python, text


def user_text(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["messages"])
            if item.get("role") == "user"
        ),
        "",
    )


LINES = 3000  # ~200 KiB, past the 64 KiB preview and the ascii shortcut

# Grows by 8 MiB every 50 ms until the cap stops it; the chunks stay in the
# namespace, so the kernel is still past the cap when the next cell starts.
HOG = (
    "import time\n"
    "chunks = []\n"
    "while True:\n"
    "    chunks.append(bytearray(8 * 1024 * 1024))\n"
    "    time.sleep(0.05)\n"
)


# exclusive: the memory cap is daemon environment
@exclusive
class CellLimitsTests(unittest.TestCase):
    def setUp(self):
        self.results = []

        def script(request):
            last = request["messages"][-1]
            if last.get("role") == "tool":
                self.results.append(json.loads(last["content"]))
                return text("noted")
            user = user_text(request)
            if "read the spill" in user:
                return python(
                    f"print(files.read({self.spill!r}, start_line={LINES - 1}))"
                )
            if "spill" in user:
                return python(
                    f"for i in range({LINES}):\n"
                    "    print(f'line {i:05d} ' + 'x' * 60)\n"
                    "print('the last line')"
                )
            if "hog" in user:
                return python(HOG)
            if "free" in user:
                return python("import gc\ndel chunks\ngc.collect()\nprint('freed')")
            return text("done")

        def prepare(app):
            app.env["ALBEDO_KERNEL_MEMORY_BYTES"] = str(96 * 1024 * 1024)

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def cell(self, prompt):
        self.app.prompt(self.session, prompt).close()
        self.app.idle(self.session)
        return self.results[-1]

    def test_output_past_the_preview_is_spilled_whole(self):
        result = self.cell("spill")
        self.assertEqual(result["status"], "ok")
        self.assertTrue(result["truncated"])
        self.assertIn("line 00000", result["output"])
        self.assertNotIn("the last line", result["output"].split("[output was")[0])
        note = result["output"].rsplit("[output was", 1)[1]
        self.spill = note.split(" in ", 1)[1].split(":")[0]
        self.assertEqual(
            os.path.dirname(self.spill), str(self.app.home / "output"), self.spill
        )
        with open(self.spill, "rb") as spilled:
            content = spilled.read()
        self.assertTrue(content.startswith(b"line 00000 xxx"), content[:40])
        self.assertTrue(content.endswith(b"the last line\n"), content[-40:])
        self.assertTrue(
            note.startswith(f" {len(content)} bytes; all of it is in"), note
        )
        read = self.cell("read the spill")
        self.assertIn(f"line {LINES - 1:05d}", read["output"])
        self.assertIn("the last line", read["output"])

    def test_a_cell_past_the_memory_cap_is_interrupted_and_the_namespace_kept(self):
        hog = self.cell("hog")
        self.assertEqual(hog["status"], "interrupted", hog)
        self.assertIn("kernel memory passed its cap", hog["output"])
        self.assertIn("cap 96 MiB", hog["output"])
        # Over the cap already, a cell that frees memory still runs.
        freed = self.cell("free")
        self.assertEqual(freed["status"], "ok", freed)
        self.assertEqual(freed["output"].strip(), "freed")
        # The memory really went: the next hog is stopped at the cap again.
        again = self.cell("hog")
        self.assertEqual(again["status"], "interrupted", again)
        self.assertIn("kernel memory passed its cap", again["output"])
