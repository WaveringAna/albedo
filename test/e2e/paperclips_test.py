"""The vent channel must record model complaints for user review, share one
global ledger across sessions and workspaces, and let /paperclips triage
reach the model — with a reply recorded on the vent and delivered to the
session that filed it.

The ledger is global, so the shared daemon's store carries vents from every
test in the run, in parallel: assertions scope to the vent ids each test
files, never to the whole listing."""

import ast
import json
import sqlite3
import unittest

from harness import Albedo, Provider, exclusive, python, text

VENT = (
    "v = await vent('harness', 'the build lock ate my afternoon',"
    " suggestion='prebuild the cli in test.sh', title='build lock stalls')\n"
    "print(v['id'])"
)

# 200, not the default 20: the global ledger carries every parallel test's
# vents, and a listed id must never fall off the window.
READ_BACK = "print([(v['id'], v['status']) for v in await vents(200)])"

# Prints the vent this session filed, then the whole global listing: the
# second line proves another session's vent is visible to the model.
VENT_AND_LIST = (
    "v = await vent('harness', 'the build lock ate my afternoon',"
    " suggestion='prebuild the cli in test.sh', title='build lock stalls')\n"
    "print(v['id'])\n"
    "print([v['id'] for v in await vents(200)])"
)

READER_TURN = "print('the reader turns')"

TITLELESS = (
    "v = await vent('bug', 'wires crossed somewhere deep in the stack')\nprint(v['id'])"
)

REJECTED = (
    "try:\n"
    "    await vent('nonsense', 'no such topic')\n"
    "except Exception as error:\n"
    "    print('rejected:', error)\n"
    "try:\n"
    "    await vent('bug', '   ')\n"
    "except Exception as error:\n"
    "    print('rejected:', error)\n"
    "print([v['id'] for v in await vents(200)"
    " if v['message'] in ('no such topic', '   ')])"
)


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


def filed_id(app, session):
    """The vent id the session's first cell printed."""
    output = python_results(app, session)[0]["output"]
    return int(output.strip())


def statuses(app, session):
    """The id -> status map the session's latest listing printed."""
    output = python_results(app, session)[-1]["output"]
    return dict(ast.literal_eval(output.strip()))


def vent_row(page, vent_id):
    return next(row for row in page["rows"] if row["id"] == str(vent_id))


def glance_ids(page):
    return {row["id"] for row in page["glance"]["rows"]}


def paperclips_page(app, session):
    return json.load(
        app.api(
            f"/sessions/{session}/commands",
            {"name": "/paperclips", "args": {}},
        )
    )["result"]["page"]


def triage(app, session, action, details):
    return json.load(
        app.api(
            f"/sessions/{session}/commands",
            {"name": "/paperclips", "args": {"action": action, "details": details}},
        )
    )["result"]


class PaperclipsTests(unittest.TestCase):
    def remove_vents(self, app, session, ids):
        """Keeps one test's vents out of the next test's global listing."""
        for vent_id in ids:
            triage(app, session, "remove", str(vent_id))

    def test_vents_share_one_global_ledger(self):
        provider = scripting([VENT, VENT_AND_LIST])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            sessions = []
            ids = []
            try:
                outputs = {}
                for name in ("vent-first", "vent-second"):
                    workspace = app.root / name
                    workspace.mkdir()
                    session = app.session(workspace)
                    sessions.append(session)
                    app.prompt(session, "vent about the build").close()
                    app.idle(session)
                    results = python_results(app, session)
                    self.assertEqual(len(results), 1)
                    self.assertEqual(results[0]["status"], "ok", results[0])
                    outputs[name] = results[0]["output"].strip().splitlines()
                    ids.append(int(outputs[name][0]))
                # the second session's python list already carries the
                # first's vent: the model sees every session's vents
                listed = ast.literal_eval(outputs["vent-second"][1])
                self.assertIn(ids[0], listed)
                # and the first session's own /paperclips page shows both
                page = paperclips_page(app, sessions[0])
                rows = {row["id"] for row in page["rows"]}
                self.assertTrue({str(vent_id) for vent_id in ids} <= rows)
                self.assertTrue({str(vent_id) for vent_id in ids} <= glance_ids(page))
            finally:
                if ids:
                    self.remove_vents(app, sessions[0], ids)

    def test_user_triage_reaches_the_model(self):
        provider = scripting([VENT, READ_BACK])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            workspace = app.root / "vent-triage"
            workspace.mkdir()
            session = app.session(workspace)
            vent_id = None
            try:
                app.prompt(session, "vent about the build").close()
                app.idle(session)
                vent_id = filed_id(app, session)

                # a named session shows by name in the detail pane
                app.api(
                    f"/sessions/{session}", {"name": "grumpy-venter"}, method="PATCH"
                )

                page = paperclips_page(app, session)
                # the list shows the model's title; the detail carries the vent
                row = vent_row(page, vent_id)
                self.assertEqual(row["text"], "build lock stalls")
                self.assertEqual(row["badge"], "open")
                self.assertIn("the build lock ate my afternoon", row["detail"])
                self.assertIn("suggestion: prebuild the cli in test.sh", row["detail"])
                self.assertIn("by session grumpy-venter", row["detail"])
                self.assertIn(str(vent_id), glance_ids(page))

                replied = triage(
                    app, session, "reply", f"{vent_id} test.sh prebuilds the cli now"
                )
                self.assertIn("the model will be told", replied["message"])
                self.assertEqual(replied["vent"]["status"], "acknowledged")
                self.assertEqual(
                    replied["vent"]["reply"], "test.sh prebuilds the cli now"
                )

                page = paperclips_page(app, session)
                self.assertEqual(vent_row(page, vent_id)["badge"], "acknowledged")
                self.assertIn(
                    "answered: test.sh prebuilds the cli now",
                    vent_row(page, vent_id)["detail"],
                )
                self.assertNotIn(str(vent_id), glance_ids(page))

                # the note reaches the model with its next turn; the ledger agrees
                app.prompt(session, "check your vents").close()
                app.idle(session)
                results = python_results(app, session)
                self.assertEqual(len(results), 2)
                self.assertEqual(statuses(app, session)[vent_id], "acknowledged")
                # the queued note reaches the model as its own user turn
                self.assertTrue(
                    any(
                        "answers: test.sh prebuilds the cli now"
                        in str(message.get("content"))
                        for request in provider.requests
                        for message in request["request"]["messages"]
                    )
                )
            finally:
                if vent_id is not None:
                    self.remove_vents(app, session, [vent_id])

    def test_a_reply_reaches_the_session_that_vented(self):
        provider = scripting([VENT, READ_BACK, READER_TURN])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            sessions = {}
            for name in ("vent-filer", "vent-reader"):
                workspace = app.root / name
                workspace.mkdir()
                sessions[name] = app.session(workspace)
            filer = sessions["vent-filer"]
            reader = sessions["vent-reader"]
            vent_id = None
            try:
                app.prompt(filer, "vent about the build").close()
                app.idle(filer)
                vent_id = filed_id(app, filer)

                # the reader sees the filer's vent, attributed to its workspace
                page = paperclips_page(app, reader)
                row = vent_row(page, vent_id)
                self.assertEqual(row["badge"], "open")
                self.assertIn("vent-filer", row["detail"])

                replied = triage(app, reader, "reply", f"{vent_id} the reader answers")
                self.assertIn("the model will be told", replied["message"])
                self.assertEqual(replied["vent"]["status"], "acknowledged")

                # the note lands on the filer's next turn...
                app.prompt(filer, "check your vents").close()
                app.idle(filer)
                results = python_results(app, filer)
                self.assertEqual(len(results), 2)
                self.assertEqual(statuses(app, filer)[vent_id], "acknowledged")
                self.assertIn(
                    "answers: the reader answers",
                    str(provider.requests[-1]["request"]["messages"]),
                )
                # ...and not on the reader's, which turns afterwards. Each
                # python turn spans two requests (tool call, then its
                # result), so the requests carrying the note are identified
                # by the filer's prompt, not by position.
                app.prompt(reader, "anything for me?").close()
                app.idle(reader)
                noted = [
                    request
                    for request in provider.requests
                    if "answers: the reader answers"
                    in str(request["request"]["messages"])
                ]
                self.assertTrue(noted)
                for request in noted:
                    self.assertIn(
                        "check your vents",
                        str(request["request"]["messages"]),
                    )
                    self.assertNotIn(
                        "anything for me?",
                        str(request["request"]["messages"]),
                    )
            finally:
                if vent_id is not None:
                    self.remove_vents(app, reader, [vent_id])

    @exclusive
    def test_an_undeliverable_reply_is_kept_on_the_vent(self):
        """A reply survives its note: the answer is durable on the vent even
        when the session that filed it is gone or was never recorded."""
        provider = Provider(lambda request: text("done"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            database = app.home / "albedo.sqlite"

            def prepare(_app):
                with sqlite3.connect(database) as db:
                    db.execute(
                        "INSERT INTO paperclips(topic,message,cwd,session) "
                        "VALUES('bug','ghost vent',?,'no-such-session')",
                        (str(app.workspace),),
                    )
                    db.execute(
                        "INSERT INTO paperclips(topic,message,cwd) "
                        "VALUES('bug','sessionless vent',?)",
                        (str(app.workspace),),
                    )

            app.restart(prepare=prepare)
            ids = {}
            try:
                page = paperclips_page(app, session)
                for text_label in ("ghost vent", "sessionless vent"):
                    row = next(r for r in page["rows"] if r["text"] == text_label)
                    self.assertEqual(row["badge"], "open")
                    ids[text_label] = int(row["id"])

                gone = triage(
                    app, session, "reply", f"{ids['ghost vent']} for the ghost"
                )
                self.assertIn("could not tell the model", gone["message"])
                self.assertIn("the answer is kept on the vent", gone["message"])
                self.assertEqual(gone["vent"]["status"], "acknowledged")
                self.assertEqual(gone["vent"]["reply"], "for the ghost")

                nobody = triage(
                    app, session, "reply", f"{ids['sessionless vent']} for nobody"
                )
                self.assertIn("could not tell the model", nobody["message"])
                self.assertIn("the vent records no session", nobody["message"])
                self.assertEqual(nobody["vent"]["status"], "acknowledged")
                self.assertEqual(nobody["vent"]["reply"], "for nobody")

                # the answers are on the vents, and neither stays in the glance
                page = paperclips_page(app, session)
                self.assertIn(
                    "answered: for the ghost",
                    vent_row(page, ids["ghost vent"])["detail"],
                )
                self.assertIn(
                    "answered: for nobody",
                    vent_row(page, ids["sessionless vent"])["detail"],
                )
                self.assertFalse(
                    {str(vent_id) for vent_id in ids.values()} & glance_ids(page)
                )
            finally:
                self.remove_vents(app, session, list(ids.values()))

    def test_a_titleless_vent_takes_its_title_from_the_message(self):
        provider = scripting([TITLELESS])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            vent_id = None
            try:
                app.prompt(session, "vent").close()
                app.idle(session)
                vent_id = filed_id(app, session)
                row = vent_row(paperclips_page(app, session), vent_id)
                self.assertEqual(
                    row["text"], "wires crossed somewhere deep in the stack"
                )
                self.assertIn("wires crossed", row["detail"])
            finally:
                if vent_id is not None:
                    self.remove_vents(app, session, [vent_id])

    def test_a_vent_needs_a_known_topic_and_a_message(self):
        provider = scripting([REJECTED])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "vent something").close()
            app.idle(session)
            results = python_results(app, session)
            self.assertEqual(results[0]["status"], "ok", results[0])
            # both attempts were rejected — the whitespace message included
            self.assertEqual(results[0]["output"].count("rejected:"), 2)
            # and neither left a vent in the global ledger
            self.assertTrue(results[0]["output"].strip().endswith("[]"))


if __name__ == "__main__":
    unittest.main()
