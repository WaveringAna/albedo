"""The vent channel must record model complaints for user review, keep them
scoped by session workspace, and let /paperclips triage reach the model."""

import json
import unittest

from harness import Albedo, Provider, python, text

VENT_AND_LIST = (
    "await vent('harness', 'the build lock ate my afternoon',"
    " suggestion='prebuild the cli in test.sh', title='build lock stalls')\n"
    "print([(v['id'], v['topic'], v['status']) for v in await vents()])"
)

READ_BACK = "print([(v['id'], v['status']) for v in await vents()])"


def scripting(cells):
    """Answers each user turn with the next scripted python cell."""

    def reply(request):
        if request["messages"][-1].get("role") == "user" and cells:
            return python(cells.pop(0))
        return text("done")

    return Provider(reply)


def python_results(app, session):
    return [
        json.loads(event["result"])
        for event in app.events(session)
        if event.get("type") == "tool" and event.get("name") == "python"
    ]


class PaperclipsTests(unittest.TestCase):
    def test_vents_are_scoped_to_session_workspace(self):
        provider = scripting([VENT_AND_LIST, VENT_AND_LIST])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            outputs = []
            for name in ("vent-first", "vent-second"):
                workspace = app.root / name
                workspace.mkdir()
                session = app.session(workspace)
                app.prompt(session, "vent about the build").close()
                app.idle(session)
                results = python_results(app, session)
                self.assertEqual(len(results), 1)
                self.assertEqual(results[0]["status"], "ok", results[0])
                outputs.append(results[0]["output"])
            # each workspace sees exactly its own single open vent
            for output in outputs:
                self.assertEqual(output.count("harness"), 1)
                self.assertIn("'open'", output)

    def test_user_triage_reaches_the_model(self):
        provider = scripting([VENT_AND_LIST, READ_BACK])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            workspace = app.root / "vent-triage"
            workspace.mkdir()
            session = app.session(workspace)
            app.prompt(session, "vent about the build").close()
            app.idle(session)

            page = json.load(
                app.api(
                    f"/sessions/{session}/commands",
                    {"name": "/paperclips", "args": {}},
                )
            )["result"]["page"]
            self.assertEqual(len(page["rows"]), 1)
            # the list shows the model's title; the detail carries the vent
            self.assertEqual(page["rows"][0]["text"], "build lock stalls")
            self.assertEqual(page["rows"][0]["badge"], "open")
            self.assertIn("the build lock ate my afternoon", page["rows"][0]["detail"])
            self.assertIn(
                "suggestion: prebuild the cli in test.sh", page["rows"][0]["detail"]
            )
            self.assertEqual(len(page["glance"]["rows"]), 1)

            triage = f"/sessions/{session}/commands"
            vent_id = page["rows"][0]["id"]
            replied = json.load(
                app.api(
                    triage,
                    {
                        "name": "/paperclips",
                        "args": {
                            "action": "reply",
                            "details": f"{vent_id} test.sh prebuilds the cli now",
                        },
                    },
                )
            )["result"]
            self.assertIn("the model will be told", replied["message"])
            self.assertEqual(replied["vent"]["status"], "acknowledged")

            page = json.load(app.api(triage, {"name": "/paperclips", "args": {}}))[
                "result"
            ]["page"]
            self.assertEqual(page["rows"][0]["badge"], "acknowledged")
            self.assertEqual(page["glance"]["rows"], [])

            # the note reaches the model with its next turn; the ledger agrees
            app.prompt(session, "check your vents").close()
            app.idle(session)
            results = python_results(app, session)
            self.assertEqual(len(results), 2)
            self.assertEqual(results[1]["status"], "ok", results[1])
            self.assertIn("'acknowledged'", results[1]["output"])
            # the queued note reaches the model as its own user turn
            self.assertTrue(
                any(
                    "answers: test.sh prebuilds the cli now"
                    in str(message.get("content"))
                    for request in provider.requests
                    for message in request["request"]["messages"]
                )
            )

    def test_a_titleless_vent_takes_its_title_from_the_message(self):
        provider = scripting(
            ["await vent('bug', 'wires crossed somewhere deep in the stack')\n"]
        )
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "vent").close()
            app.idle(session)
            page = json.load(
                app.api(
                    f"/sessions/{session}/commands",
                    {"name": "/paperclips", "args": {}},
                )
            )["result"]["page"]
            self.assertEqual(
                page["rows"][0]["text"], "wires crossed somewhere deep in the stack"
            )
            self.assertIn("wires crossed", page["rows"][0]["detail"])

    def test_a_vent_needs_a_known_topic_and_a_message(self):
        provider = scripting(
            [
                "try:\n"
                "    await vent('nonsense', 'no such topic')\n"
                "except Exception as error:\n"
                "    print('rejected:', error)\n"
                "try:\n"
                "    await vent('bug', '   ')\n"
                "except Exception as error:\n"
                "    print('rejected:', error)\n"
                "print(len(await vents()))",
            ]
        )
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "vent something").close()
            app.idle(session)
            results = python_results(app, session)
            self.assertEqual(results[0]["status"], "ok", results[0])
            self.assertEqual(results[0]["output"].count("rejected:"), 2)
            self.assertTrue(results[0]["output"].strip().endswith("0"))


if __name__ == "__main__":
    unittest.main()
