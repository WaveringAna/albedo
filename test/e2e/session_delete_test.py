"""Deleting a session removes every row any table keeps for it.

The delete route clears a list of tables the daemon names itself, so a table an
extension adds is forgotten until someone remembers to add it. The check reads
the schema, so it covers a table nobody has listed yet.
"""

import json
import sqlite3
import unittest

from harness import Albedo, Provider, text

# The paperclip ledger keeps a vent's session id as provenance, not ownership.
KEPT = {"paperclips"}


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
        with self.app.api(
            f"/sessions/{session}/commands",
            {"name": "/compact", "arguments": strategy},
        ) as response:
            self.assertTrue(json.load(response)["result"]["started"])
        self.app.idle(session)
        return session

    def assert_delete_clears(self, strategy, table):
        session = self.compacted_session(strategy)
        with self.database() as db:
            self.assertGreater(self.rows(db, table, session), 0, table)
            self.assertIn(table, self.keyed_tables(db))
        with self.app.api(f"/sessions/{session}", method="DELETE") as response:
            self.assertEqual(response.status, 200)
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

    def test_rolling_and_notes_rows_go_with_the_session(self):
        self.assert_delete_clears("rolling", "compaction_notes")

    def test_lcm_rows_go_with_the_session(self):
        self.assert_delete_clears("lcm", "lcm_compaction_node")

    def test_snapcompact_archive_goes_with_the_session(self):
        self.assert_delete_clears("snapcompact", "snapcompact_archive")


if __name__ == "__main__":
    unittest.main()
