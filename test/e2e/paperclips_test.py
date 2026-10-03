"""The vent channel must record model complaints for user review, share one
global ledger across sessions and workspaces, and let /paperclips triage
reach the model — with a reply recorded on the vent and delivered to the
session that filed it.

Each scenario has an isolated daemon because the model's bounded global
listing has no page cursor. Sessions within a scenario still share one ledger."""

import ast
import json
import sqlite3
import unittest

from harness import Albedo, Provider, exclusive, python, text

VENT = (
    "v = await vent('harness', 'a background job stopped responding',"
    " suggestion='report the blocked job', title='job stalled')\n"
    "print(v['id'])"
)

READ_BACK = "print([(v['id'], v['status']) for v in await vents()])"

# Prints the vent this session filed, then the whole global listing: the
# second line proves another session's vent is visible to the model.
VENT_AND_LIST = (
    "v = await vent('harness', 'a background job stopped responding',"
    " suggestion='report the blocked job', title='job stalled')\n"
    "print(v['id'])\n"
    "print([v['id'] for v in await vents()])"
)

READER_TURN = "print('the reader turns')"

# Refused without a note, closed with one, then refused as already closed.
RESOLVE = (
    "vent_id = v['id']\n"
    "for note in ('  ', 'the blocked job now reports its state', 'again'):\n"
    "    try:\n"
    "        v = await resolve_vent(vent_id, note)\n"
    "        print('resolved:', v['status'], v['resolution'])\n"
    "    except Exception as error:\n"
    "        print('refused:', error)"
)

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
    "print([v['id'] for v in await vents()"
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
        json.loads(part["value"])
        for entry in app.history(session)["items"]
        if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
        for part in entry["content"]
        if part["kind"] == "json" and part["field"] == "result"
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
    return next(
        resource["value"]
        for resource in page["items"]
        if resource["value"]["id"] == str(vent_id)
    )


def glance_ids(app, session):
    with app.api(f"/sessions/{session}?tail=0") as response:
        glances = json.load(response)["glances"]
    return {
        row["id"]
        for glance in glances
        if glance["extension"] == "paperclips"
        for row in glance["rows"]
    }


def paperclips_page(app):
    with app.api("/extensions/paperclips/items?limit=200") as response:
        return json.load(response)


def reply_to_vent(app, vent_id, message):
    route = f"/extensions/paperclips/items/{vent_id}"
    with app.api(route) as response:
        json.load(response)
        revision = response.headers["ETag"]
    with app.api(
        route, {"reply": message}, method="PATCH", headers={"If-Match": revision}
    ) as response:
        return json.load(response)


def rename(app, session, name):
    with app.api(f"/sessions/{session}?view=configuration") as response:
        json.load(response)
        revision = response.headers["ETag"]
    app.api(
        f"/sessions/{session}?view=configuration",
        {"name": name},
        method="PATCH",
        headers={"If-Match": revision},
    ).close()


@exclusive
class PaperclipsTests(unittest.TestCase):
    def remove_vents(self, app, session, ids):
        """Keeps one test's vents out of the next test's global listing."""
        for vent_id in ids:
            route = f"/extensions/paperclips/items/{vent_id}"
            with app.api(route) as response:
                json.load(response)
                revision = response.headers["ETag"]
            app.api(route, method="DELETE", headers={"If-Match": revision}).close()

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
                page = paperclips_page(app)
                rows = {item["value"]["id"] for item in page["items"]}
                self.assertTrue({str(vent_id) for vent_id in ids} <= rows)
                self.assertTrue(
                    {str(vent_id) for vent_id in ids} <= glance_ids(app, sessions[0])
                )
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
                rename(app, session, "grumpy-venter")

                page = paperclips_page(app)
                # the list shows the model's title; the detail carries the vent
                row = vent_row(page, vent_id)
                self.assertEqual(row["title"], "job stalled")
                self.assertEqual(row["status"], "open")
                self.assertEqual(row["message"], "a background job stopped responding")
                self.assertEqual(row["suggestion"], "report the blocked job")
                self.assertEqual(row["session_id"], session)
                self.assertIn(str(vent_id), glance_ids(app, session))

                replied = reply_to_vent(app, vent_id, "the blocked job is now visible")
                self.assertEqual(replied["notification"]["state"], "queued")
                self.assertEqual(replied["resource"]["value"]["status"], "acknowledged")
                self.assertEqual(
                    replied["resource"]["value"]["reply"],
                    "the blocked job is now visible",
                )

                page = paperclips_page(app)
                self.assertEqual(vent_row(page, vent_id)["status"], "acknowledged")
                self.assertIn(
                    "the blocked job is now visible",
                    vent_row(page, vent_id)["reply"],
                )
                self.assertNotIn(str(vent_id), glance_ids(app, session))

                # the note reaches the model with its next turn; the ledger agrees
                app.prompt(session, "check your vents").close()
                app.idle(session)
                results = python_results(app, session)
                self.assertEqual(len(results), 2)
                self.assertEqual(statuses(app, session)[vent_id], "acknowledged")
                # the queued note reaches the model as its own user turn
                self.assertTrue(
                    any(
                        "answers: the blocked job is now visible"
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
                page = paperclips_page(app)
                row = vent_row(page, vent_id)
                self.assertEqual(row["status"], "open")
                self.assertEqual(row["session_id"], filer)
                self.assertIn("vent-filer", row["workspace"])

                replied = reply_to_vent(app, vent_id, "the reader answers")
                self.assertEqual(replied["notification"]["state"], "queued")
                self.assertEqual(replied["resource"]["value"]["status"], "acknowledged")

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

    # exclusive: restarts the daemon to load seeded vents
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
                page = paperclips_page(app)
                for text_label in ("ghost vent", "sessionless vent"):
                    row = next(
                        item["value"]
                        for item in page["items"]
                        if item["value"]["message"] == text_label
                    )
                    self.assertEqual(row["status"], "open")
                    ids[text_label] = int(row["id"])

                gone = reply_to_vent(app, ids["ghost vent"], "for the ghost")
                self.assertNotEqual(gone["notification"]["state"], "queued")
                self.assertEqual(gone["resource"]["value"]["status"], "acknowledged")
                self.assertEqual(gone["resource"]["value"]["reply"], "for the ghost")

                nobody = reply_to_vent(app, ids["sessionless vent"], "for nobody")
                self.assertNotEqual(nobody["notification"]["state"], "queued")
                self.assertEqual(nobody["resource"]["value"]["status"], "acknowledged")
                self.assertEqual(nobody["resource"]["value"]["reply"], "for nobody")

                # the answers are on the vents, and neither stays in the glance
                page = paperclips_page(app)
                self.assertIn(
                    "for the ghost",
                    vent_row(page, ids["ghost vent"])["reply"],
                )
                self.assertIn(
                    "for nobody",
                    vent_row(page, ids["sessionless vent"])["reply"],
                )
                self.assertFalse(
                    {str(vent_id) for vent_id in ids.values()}
                    & glance_ids(app, session)
                )
            finally:
                self.remove_vents(app, session, list(ids.values()))

    def test_the_model_resolves_a_vent_it_fixed_with_a_note(self):
        provider = scripting([VENT, RESOLVE])
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            vent_id = None
            try:
                app.prompt(session, "vent about the build").close()
                app.idle(session)
                vent_id = filed_id(app, session)
                app.prompt(session, "you fixed it, close it").close()
                app.idle(session)

                output = python_results(app, session)[-1]["output"]
                lines = output.strip().splitlines()
                self.assertEqual(len(lines), 3, output)
                self.assertIn("refused: say what fixed the vent", lines[0])
                self.assertEqual(
                    lines[1], "resolved: resolved the blocked job now reports its state"
                )
                self.assertIn(f"refused: vent #{vent_id} is already resolved", lines[2])

                # the user sees the closure and who made it; it leaves the glance
                rename(app, session, "fixer")
                page = paperclips_page(app)
                row = vent_row(page, vent_id)
                self.assertEqual(row["status"], "resolved")
                self.assertEqual(row["resolving_session_id"], session)
                self.assertEqual(
                    row["resolution"], "the blocked job now reports its state"
                )
                self.assertNotIn(str(vent_id), glance_ids(app, session))
            finally:
                if vent_id is not None:
                    self.remove_vents(app, session, [vent_id])

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
                row = vent_row(paperclips_page(app), vent_id)
                self.assertEqual(
                    row["title"], "wires crossed somewhere deep in the stack"
                )
                self.assertIn("wires crossed", row["message"])
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
