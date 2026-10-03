"""Deleting a session removes every row any table keeps for it.

The delete route clears a list of tables the daemon names itself, so a table an
extension adds is forgotten until someone remembers to add it. The check reads
the schema, so it covers a table nobody has listed yet.
"""

import json
import sqlite3
import threading
import unittest
import urllib.parse
import urllib.error

from harness import Albedo, Provider, operation_id, text

# Paperclip provenance and retained input outcomes outlive the session.
KEPT = {"paperclips", "input_turns"}


def reply(request):
    return text("older conversation summary")


class SessionDeleteTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def database(self):
        return sqlite3.connect(
            f"file:{self.app.home / 'albedo.sqlite'}?mode=ro", uri=True
        )

    def keyed_tables(self, db):
        tables = [
            row[0]
            for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        ]
        return [
            table
            for table in tables
            if table not in KEPT
            and any(
                column[1] == "session"
                for column in db.execute(f"PRAGMA table_info({table})")
            )
        ]

    def rows(self, db, table, session):
        return db.execute(
            f"SELECT count(*) FROM {table} WHERE session=?", (session,)
        ).fetchone()[0]

    def compacted_session(self, strategy):
        session = self.app.session()
        # Long enough that a forced compaction has something to evict.
        for prompt in ("first", "second", "third", "fourth"):
            self.app.prompt(session, prompt + " " + "x" * 6000).close()
            self.app.idle(session)
        self.compact(session, strategy)
        return session

    def compact(self, session, strategy):
        with self.app.api(
            f"/sessions/{session}/compaction",
            {"strategy": strategy},
        ) as response:
            self.assertEqual(json.load(response)["state"], "compacted")
        self.app.idle(session)

    def delete_session(self, session):
        resource = f"/sessions/{session}?view=configuration"
        with self.app.api(resource) as response:
            validator = response.getheader("ETag")
            response.read()
        with self.app.api(
            resource, method="DELETE", headers={"If-Match": validator}
        ) as response:
            self.assertEqual(json.load(response)["state"], "complete")

    def assert_delete_clears(self, strategy, table, then=None):
        session = self.compacted_session(strategy)
        with self.database() as db:
            self.assertGreater(self.rows(db, table, session), 0, table)
            self.assertIn(table, self.keyed_tables(db))
        if then:
            self.compact(session, then)
            with self.database() as db:
                self.assertGreater(self.rows(db, table, session), 0, table)
        self.delete_session(session)
        with self.database() as db:
            left = {
                name: self.rows(db, name, session) for name in self.keyed_tables(db)
            }
            self.assertEqual({k: v for k, v in left.items() if v}, {})
            orphans = db.execute(
                "SELECT count(*) FROM lcm_compaction_edge WHERE child NOT IN "
                "(SELECT id FROM lcm_compaction_node) OR parent NOT IN "
                "(SELECT id FROM lcm_compaction_node)"
            ).fetchone()[0]
            self.assertEqual(orphans, 0)

    def test_leaf_deletion_refuses_busy_and_stale_observations(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        def held(request):
            entered.set()
            release.wait(30)
            return text("completed before deletion")

        self.provider.script = held
        session = self.app.session()
        resource = f"/sessions/{session}?view=configuration"
        with self.app.api(resource) as response:
            revision = response.headers["ETag"]
            response.read()
        identity = operation_id()
        with self.app.api(
            f"/sessions/{session}/inputs/{identity}",
            {"kind": "message", "text": "hold deletion"},
            method="PUT",
        ) as response:
            response.read()
        self.assertTrue(entered.wait(30))
        with self.app.api(resource) as response:
            revision = response.headers["ETag"]
            response.read()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.app.api(resource, method="DELETE", headers={"If-Match": revision})
        self.assertEqual(caught.exception.code, 409)
        release.set()
        self.app.idle(session)
        with self.app.api(resource) as response:
            revision = response.headers["ETag"]
            response.read()
        with self.app.api(
            resource,
            {"name": "changed before deletion"},
            method="PATCH",
            headers={"If-Match": revision},
        ) as response:
            response.read()
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.app.api(resource, method="DELETE", headers={"If-Match": revision})
        self.assertEqual(caught.exception.code, 412)
        with self.app.api(f"/sessions/{session}") as response:
            self.assertEqual(json.load(response)["name"], "changed before deletion")
        self.delete_session(session)
        with self.app.api(f"/sessions/{session}/inputs/{identity}") as response:
            receipt = json.load(response)
        self.assertEqual(receipt["delivery"], "committed")
        self.assertEqual(receipt["turn"]["state"], "completed")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.app.api(f"/sessions/{session}")
        self.assertEqual(caught.exception.code, 410)
        self.assertEqual(json.load(caught.exception)["code"], "session_deleted")

    def test_rolling_and_notes_rows_go_with_the_session(self):
        self.assert_delete_clears("rolling", "compaction_notes")

    def test_lcm_rows_go_with_the_session(self):
        self.assert_delete_clears("lcm", "lcm_compaction_node")

    def test_rows_of_a_strategy_switched_off_go_too(self):
        # Switching to rolling disables lcm; its graph still belongs to the session.
        self.assert_delete_clears("lcm", "lcm_compaction_node", then="rolling")

    def test_work_and_schedule_rows_go_with_the_session(self):
        session = self.app.session()
        with self.app.api(
            "/extensions/schedule/jobs",
            {
                "session_id": session,
                "kind": "once",
                "delay_seconds": 3600,
                "prompt": "build",
            },
        ) as response:
            response.read()
        with self.app.api(
            "/extensions/work/items?"
            + urllib.parse.urlencode({"workspace": str(self.app.workspace)}),
            {"title": "assigned", "session_id": session},
        ) as response:
            response.read()
        with self.database() as db:
            for table in ("work", "schedules"):
                self.assertGreater(self.rows(db, table, session), 0, table)
        self.delete_session(session)
        with self.database() as db:
            for table in ("work", "schedules"):
                self.assertEqual(self.rows(db, table, session), 0, table)

    def test_snapcompact_archive_goes_with_the_session(self):
        self.assert_delete_clears("snapcompact", "snapcompact_archive")


if __name__ == "__main__":
    unittest.main()
