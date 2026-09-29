"""Python work routes must isolate ledger reads and writes by session workspace."""

import json
import unittest

from harness import Albedo, Provider, python, text


class WorkTests(unittest.TestCase):
    def test_python_work_is_scoped_to_session_workspace(self):
        provider = Provider(
            lambda request: (
                python(
                    "import os\n"
                    "name = os.path.basename(os.getcwd())\n"
                    "await work.create(title=name)\n"
                    "print([item['title'] for item in await work.list()])"
                )
                if request["messages"][-1].get("role") == "user"
                else text("done")
            )
        )
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            outputs = []
            for name in ("work-first", "work-second"):
                workspace = app.root / name
                workspace.mkdir()
                session = app.session(workspace)
                app.prompt(session, "use work").close()
                app.idle(session)
                results = [
                    json.loads(event["result"])
                    for event in app.events(session)
                    if event.get("type") == "tool" and event.get("name") == "python"
                ]
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["status"], "ok", results[0])
                outputs.append(results[0]["output"])
            self.assertIn("work-first", outputs[0])
            self.assertNotIn("work-second", outputs[0])
            self.assertIn("work-second", outputs[1])
            self.assertNotIn("work-first", outputs[1])
