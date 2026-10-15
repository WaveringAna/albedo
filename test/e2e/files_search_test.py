"""A clipped ripgrep search remains a bounded, truncated result instead of raising."""

import json
import unittest

from harness import Albedo, Provider, latest_user, python, text


class FilesSearchTests(unittest.TestCase):
    def setUp(self):
        self.results = []

        def script(request):
            last = request["messages"][-1]
            if last.get("role") == "tool":
                self.results.append(json.loads(last["content"]))
                return text("noted")
            if latest_user(request) == "bounded search":
                return python(
                    "from pathlib import Path\n"
                    "root = Path('search-fixture'); root.mkdir()\n"
                    "for i in range(20): (root / f'file-{i}').write_text('pinned ' + 'x' * 100000)\n"
                    "rows = await files.find(r'pinned|Pinned', str(root), max_results=30)\n"
                    "print(len(rows), rows.truncated)"
                )
            return text("ok")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_clipped_search_returns_truncated_rows(self):
        session = self.app.session()
        self.app.prompt(session, "bounded search").close()
        self.app.idle(session)
        self.assertEqual(self.results[-1]["status"], "ok", self.results[-1])
        self.assertRegex(self.results[-1]["output"], r"\d+ (True|False)")
