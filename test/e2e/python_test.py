"""File editing and search are exercised through the daemon's real Python tool."""

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

    def execute(self, code):
        self.code = code
        session = self.app.session()
        self.app.prompt(session, "use the Python tools").close()
        self.app.idle(session)
        results = [
            json.loads(event["result"])
            for event in self.app.events(session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ]
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["status"], "ok", results[0])
        return results[0]["output"]

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


if __name__ == "__main__":
    unittest.main()
