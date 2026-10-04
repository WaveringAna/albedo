"""Python work routes must isolate ledger reads and writes by session workspace."""

import json
import unittest
from urllib.parse import urlencode

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
                workspace = app.workspace / name
                workspace.mkdir()
                session = app.session(workspace)
                app.prompt(session, "use work").close()
                app.idle(session)
                results = [
                    json.loads(part["value"])
                    for entry in app.history(session)["items"]
                    if entry["kind"] == "tool_result"
                    and entry["tool"]["name"] == "python"
                    for part in entry["content"]
                    if part["kind"] == "json" and part["field"] == "result"
                ]
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["status"], "ok", results[0])
                outputs.append(results[0]["output"])
            self.assertIn("work-first", outputs[0])
            self.assertNotIn("work-second", outputs[0])
            self.assertIn("work-second", outputs[1])
            self.assertNotIn("work-first", outputs[1])

    def test_foreign_ids_cannot_be_read_changed_deleted_or_parented(self):
        foreign = {}

        def script(request):
            if request["messages"][-1].get("role") != "user":
                return text("done")
            item_id, revision = int(foreign["id"]), int(foreign["revision"])
            return python(
                f"operations = [lambda: work.get({item_id}), "
                f"lambda: work.update({item_id}, revision={revision}, title='changed'), "
                f"lambda: work.delete({item_id}, revision={revision}), "
                f"lambda: work.create(title='child', parent={item_id})]\n"
                "for operation in operations:\n"
                "    try:\n"
                "        await operation()\n"
                "    except WorkError:\n"
                "        print('REFUSED')\n"
                "    else:\n"
                "        raise AssertionError('foreign item accepted')\n"
                "print('EMPTY', await work.list())"
            )

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            query = urlencode({"workspace": str(app.workspace)})
            with app.api(
                f"/extensions/work/items?{query}",
                {"title": "original"},
                method="POST",
            ) as response:
                foreign.update(json.load(response)["resource"]["value"])
            other = app.workspace / "other-workspace"
            other.mkdir()
            session = app.session(other)
            app.prompt(session, "try foreign IDs").close()
            app.idle(session)
            results = [
                json.loads(part["value"])
                for entry in app.history(session)["items"]
                if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
                for part in entry["content"]
                if part["kind"] == "json" and part["field"] == "result"
            ]
            self.assertEqual(len(results), 1)
            self.assertEqual(results[0]["status"], "ok", results[0])
            self.assertEqual(results[0]["output"].count("REFUSED"), 4)
            self.assertIn("EMPTY []", results[0]["output"])
            with app.api(f"/extensions/work/items?{query}") as response:
                items = json.load(response)["items"]
            self.assertEqual([item["value"]["title"] for item in items], ["original"])
