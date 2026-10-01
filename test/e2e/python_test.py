"""File editing, search, and cell timing are exercised through the daemon's real Python tool."""

import json
import unittest

from harness import Albedo, Provider, python, text


class PythonToolsTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            if request["messages"][-1].get("role") == "user":
                return python(self.code)
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def run_cell(self, code, session):
        """The result of one prompt's cell, the latest in the session."""
        self.code = code
        self.app.prompt(session, "use the Python tools").close()
        self.app.idle(session)
        results = [
            json.loads(event["result"])
            for event in self.app.events(session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ]
        self.assertEqual(results[-1]["status"], "ok", results[-1])
        return results[-1]

    def execute(self, code):
        return self.run_cell(code, self.app.session())["output"]

    def test_ambiguous_edit_requires_a_hint_and_preserves_other_matches(self):
        note = self.app.workspace / "note.txt"
        note.write_text("same\nother\nsame\n")
        output = self.execute(
            "try:\n    files.edit('note.txt', 'same', 'changed')\n"
            "except Exception as exc:\n    print('ambiguous:', exc)\n"
            "files.edit('note.txt', 'same', 'changed', line_hint=3)\n"
            "print(files.read('note.txt'))"
        )
        self.assertEqual(note.read_text(), "same\nother\nchanged\n")
        self.assertIn("ambiguous:", output)
        self.assertIn("same", output)
        self.assertIn("changed", output)

    def test_find_searches_workspace_and_returns_context(self):
        (self.app.workspace / "note.txt").write_text("before\nneedle\nafter\n")
        output = self.execute(
            "rows = await files.find('needle', '.', context=1)\n"
            "print(rows)\nprint(files.read('note.txt', start_line=2, end_line=2))"
        )
        self.assertIn("note.txt", output)
        self.assertIn("needle", output)
        self.assertIn("before", output)
        self.assertIn("after", output)

    def test_paths_searches_a_list_of_directories_with_a_list_of_globs(self):
        for directory, name in [("a", "one.md"), ("b", "two.txt"), ("c", "three.md")]:
            (self.app.workspace / directory).mkdir()
            (self.app.workspace / directory / name).write_text("x")
        output = self.execute(
            "rows = await files.paths(None, ['a', 'b'], glob=['*.md', '*.txt'])\n"
            "print(sorted(str(row) for row in rows))"
        )
        self.assertIn("one.md", output)
        self.assertIn("two.txt", output)
        self.assertNotIn("three.md", output)

    def test_a_cell_reports_how_long_it_ran(self):
        session = self.app.session()
        slept = self.run_cell("import asyncio\nawait asyncio.sleep(0.3)", session)
        self.assertGreaterEqual(slept["duration"], 0.3)
        self.assertLess(slept["duration"], 5)
        # The journal keeps it, so cells.info reports it after the fact.
        info = self.run_cell(
            f"print((await cells.info({slept['cell_id']!r}))['duration'])", session
        )
        self.assertEqual(float(info["output"]), slept["duration"])
