"""Rewinding a session in place: the daemon keeps the whole conversation in an
archived session, cuts the live one back before a user message, and the next
turn sees only what is left. E2E because the cut spans the transcript, its
indexes, the registry and the actor lifecycle."""

import json
import sqlite3
import urllib.error
import urllib.parse

from harness import Provider, operation_id, text

from integration_support import IntegrationScenario, contents, script


class RewindTest(IntegrationScenario):
    def setUp(self):
        self.written = "tried the file write; it worked"

        def route(request):
            inputs = request.get("messages", request.get("input", []))
            last = next(
                (contents(i) for i in reversed(inputs) if i.get("role") == "user"), ""
            )
            if "<newly-evicted-history>" in last:
                return text(self.written)
            return script(request)

        self.provider = Provider(route)
        self.addCleanup(self.provider.close)

    def checkpoint(self, app, session, text):
        items = self.read(app, f"/sessions/{session}/history?view=checkpoints")["items"]
        return next(
            item["checkpoint_id"] for item in items if item["preview"]["text"] == text
        )

    def rewind(self, app, session, checkpoint):
        with app.api(
            f"/sessions/{session}/rewind",
            {"checkpoint_id": checkpoint},
            method="POST",
        ) as response:
            return json.load(response)

    def rewind_with_summary(self, app, session, checkpoint, summary):
        with app.api(
            f"/sessions/{session}/rewind",
            {"checkpoint_id": checkpoint, "summary": summary},
            method="POST",
        ) as response:
            return json.load(response)

    def refusal(self, app, session, checkpoint):
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.rewind(app, session, checkpoint)
        return raised.exception.code, json.load(raised.exception)["code"]

    def session_ids(self, app):
        # Only this app's workspace: every other test shares this daemon's home,
        # so a scope=all listing is a shifting page of their sessions.
        query = urllib.parse.urlencode(
            {"scope": "all", "workspace": str(app.workspace)}
        )
        return {item["id"] for item in self.read(app, f"/sessions?{query}")["items"]}

    def user_texts(self, entries):
        return [self.entry_text(e) for e in entries if e["kind"] == "user"]

    def test_rewind_archives_everything_and_cuts_before_the_message(self):
        app = self.app_for("responses")
        session = app.session()
        self.send(app, session, "continue from branch one")
        self.send(app, session, "write and inspect a file")
        self.send(app, session, "continue from branch three")
        before = self.history(app, session)
        self.assertTrue(any(e["kind"] == "tool_call" for e in before))

        rewound = self.rewind(
            app, session, self.checkpoint(app, session, "write and inspect a file")
        )
        self.assertEqual(rewound["input"], "write and inspect a file")
        self.assertIsNone(rewound["summary"])
        archive = rewound["archive_session_id"]
        self.assertNotEqual(archive, session)

        # The live session keeps only what came before the message, with its
        # preview and counts recomputed from what remains.
        after = self.history(app, session)
        self.assertEqual(self.user_texts(after), ["continue from branch one"])
        self.assertFalse(any(e["kind"] == "tool_call" for e in after))
        preview = self.read(app, f"/sessions/{session}?tail=0")["preview"]
        self.assertEqual(preview["text"], "continue from branch one")
        self.assertEqual(
            preview["transcript_count"],
            len({e["position"] for e in after if e["kind"] != "continuation"}),
        )

        # The archive holds the whole conversation, out of the way.
        kept = self.history(app, archive)
        self.assertEqual(
            self.user_texts(kept),
            [
                "continue from branch one",
                "write and inspect a file",
                "continue from branch three",
            ],
        )
        self.assertTrue(any(e["kind"] == "tool_call" for e in kept))
        configuration = self.read(app, f"/sessions/{archive}?view=configuration")
        self.assertTrue(configuration["preferences"]["archived"])
        named = self.read(app, f"/sessions/{archive}?tail=0")["name"]
        self.assertTrue(named.startswith("rewound: "))

        # The session carries on from the cut, and the model never sees the tail.
        start = len(self.provider.requests)
        self.send(app, session, "continue from branch again")
        request = self.provider.requests[start]["request"]
        sent = " ".join(
            contents(item) for item in request.get("input", request.get("messages", []))
        )
        self.assertIn("continue from branch one", sent)
        self.assertNotIn("write and inspect a file", sent)
        self.assertNotIn("continue from branch three", sent)

        # The archive is an ordinary session: it can be opened and continued.
        self.send(app, archive, "continue from branch archived")
        self.assertEqual(
            self.user_texts(self.history(app, session))[-1],
            "continue from branch again",
        )

    def test_rewind_refuses_what_it_cannot_cut(self):
        app = self.app_for("responses")
        session = app.session()
        self.send(app, session, "continue from branch one")
        checkpoint = self.checkpoint(app, session, "continue from branch one")
        assistant = next(
            e["checkpoint_id"]
            for e in self.history(app, session)
            if e["kind"] == "assistant" and e["checkpoint_id"]
        )

        # Only a user message is a place to cut.
        self.assertEqual(
            self.refusal(app, session, assistant), (404, "checkpoint_not_found")
        )
        self.assertEqual(
            self.refusal(app, session, "not-a-number"), (404, "checkpoint_not_found")
        )
        self.assertEqual(self.refusal(app, operation_id(), checkpoint)[0], 404)

        # A running turn cannot be cut from under itself.
        with app.prompt(session, "no first token"):
            self.assertEqual(
                self.refusal(app, session, checkpoint), (409, "session_busy")
            )

        # Nothing above changed the session.
        self.assertEqual(
            self.user_texts(self.history(app, session))[0], "continue from branch one"
        )

    def sent(self, request):
        return " ".join(
            contents(item) for item in request.get("input", request.get("messages", []))
        )

    def test_a_summary_of_the_removed_tail_reaches_the_next_request(self):
        app = self.app_for("responses")
        session = app.session()
        self.send(app, session, "continue from branch one")
        self.send(app, session, "write and inspect a file")
        self.send(app, session, "continue from branch three")

        rewound = self.rewind_with_summary(
            app,
            session,
            self.checkpoint(app, session, "write and inspect a file"),
            {"instructions": "keep file names"},
        )
        self.assertEqual(rewound["summary"], self.written)
        self.assertEqual(
            self.user_texts(self.history(app, session))[0], "continue from branch one"
        )

        # The summarizer saw the removed tail, asked as the user wished, and
        # was not shown the part that stays.
        asked = next(
            r["request"]
            for r in self.provider.requests
            if "<newly-evicted-history>" in self.sent(r["request"])
        )
        self.assertIn("write and inspect a file", self.sent(asked))
        self.assertIn("keep file names", json.dumps(asked))

        # The model that carries on is told what was removed, and nothing else
        # of it.
        start = len(self.provider.requests)
        self.send(app, session, "continue from branch again")
        sent = self.sent(self.provider.requests[start]["request"])
        self.assertIn(self.written, sent)
        self.assertIn("continue from branch one", sent)
        self.assertNotIn("continue from branch three", sent)

    def test_a_summary_that_fails_leaves_the_session_untouched(self):
        app = self.app_for("responses")
        session = app.session()
        self.send(app, session, "continue from branch one")
        self.send(app, session, "continue from branch two")
        before = self.history(app, session)
        # Scoped to this workspace, so the page cannot hide an archive either.
        sessions = self.session_ids(app)
        self.assertEqual(sessions, {session})

        self.written = ""
        with self.assertRaises(urllib.error.HTTPError) as raised:
            self.rewind_with_summary(
                app,
                session,
                self.checkpoint(app, session, "continue from branch two"),
                {},
            )
        self.assertEqual(raised.exception.code, 502)
        self.assertEqual(json.load(raised.exception)["code"], "rewind_summary_failed")

        # No cut, no archive, and the session still takes turns.
        self.assertEqual(self.history(app, session), before)
        self.assertEqual(self.session_ids(app), sessions)
        self.send(app, session, "continue from branch again")


class RewindStoredStateTest(IntegrationScenario):
    """What the transcript's positions index goes with the rows they point at.

    The cut names the tables it trims, so a table that starts keying rows by
    transcript position is forgotten until someone remembers it. The schema
    check covers one nobody has listed yet.
    """

    # Tables whose `seq` is a transcript position, and what the cut does to them.
    TRIMMED = {
        "transcript",
        "transcript_calls",
        "transcript_quarantine",
        "submission_events",
        "continuation_markers",
        "provider_requests",
    }
    # `seq` there counts something else, such as a kernel link's frames.
    UNRELATED = {"kernel_calls", "kernel_stages", "kernel_outbox", "pending_inputs"}

    def setUp(self):
        self.provider = Provider(lambda _: text("older conversation summary"))
        self.addCleanup(self.provider.close)

    def database(self, app):
        return sqlite3.connect(f"file:{app.home / 'albedo.sqlite'}?mode=ro", uri=True)

    def positioned_tables(self, db):
        tables = [
            row[0]
            for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        ]
        return {
            table
            for table in tables
            if {"session", "seq"}
            <= {column[1] for column in db.execute(f"PRAGMA table_info({table})")}
        }

    def test_the_cut_trims_every_table_keyed_by_position_and_the_lcm_graph(self):
        app = self.app_for("responses")
        session = app.session()
        for prompt in ("first", "second", "third", "fourth"):
            app.prompt(session, prompt + " " + "x" * 6000).close()
            app.idle(session)
        with app.api(
            f"/sessions/{session}/compaction", {"strategy": "lcm"}, method="POST"
        ) as response:
            self.assertEqual(json.load(response)["state"], "compacted")
        app.idle(session)
        with self.database(app) as db:
            self.assertGreater(
                db.execute(
                    "SELECT count(*) FROM lcm_compaction_node WHERE session=?",
                    (session,),
                ).fetchone()[0],
                0,
            )
            highest = db.execute(
                "SELECT max(seq) FROM transcript WHERE session=?", (session,)
            ).fetchone()[0]

        items = self.read(app, f"/sessions/{session}/history?view=checkpoints")["items"]
        checkpoint = next(
            item["checkpoint_id"]
            for item in items
            if item["preview"]["text"].startswith("third")
        )
        cut = int(checkpoint)
        with app.api(
            f"/sessions/{session}/rewind",
            {"checkpoint_id": checkpoint},
            method="POST",
        ) as response:
            json.load(response)

        with self.database(app) as db:
            positioned = self.positioned_tables(db)
            self.assertEqual(
                positioned - self.TRIMMED - self.UNRELATED,
                set(),
                "a table keyed by session and seq needs a rule in history.remove_tail",
            )
            for table in self.TRIMMED & positioned:
                stale = db.execute(
                    f"SELECT count(*) FROM {table} WHERE session=? AND seq>=? AND seq<=?",
                    (session, cut, highest),
                ).fetchone()[0]
                self.assertEqual(stale, 0, table)
            # No summary node reaches past what is kept, none is left dangling,
            # and the cursor does not claim rows that are gone.
            kept = db.execute(
                "SELECT max(seq) FROM transcript WHERE session=? AND seq<?",
                (session, cut),
            ).fetchone()[0]
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM lcm_compaction_node WHERE session=? AND last_seq>?",
                    (session, kept),
                ).fetchone()[0],
                0,
            )
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM lcm_compaction_edge WHERE child NOT IN "
                    "(SELECT id FROM lcm_compaction_node) OR parent NOT IN "
                    "(SELECT id FROM lcm_compaction_node)"
                ).fetchone()[0],
                0,
            )
            cursor = db.execute(
                "SELECT last_seq FROM lcm_compaction_state WHERE session=?", (session,)
            ).fetchone()
            self.assertTrue(cursor is None or cursor[0] <= kept)

        # The session takes a turn on what is left.
        self.send(app, session, "fifth " + "x" * 100)
