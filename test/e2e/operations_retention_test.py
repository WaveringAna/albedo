"""Retention preserves pending and unfinished turns, and deleted identities cannot revive work."""

import json
import sqlite3
import threading
import time
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text
from operations_test import InputScenario

RETENTION_MS = 7 * 24 * 60 * 60 * 1000


@exclusive
class OperationRetentionTests(InputScenario):
    def setUp(self):
        self.provider = Provider(lambda _: text("done"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            protocol="responses",
            prepare=lambda app: app.env.update(ALBEDO_SCHEDULE_TICK_MS="50"),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def database(self):
        return sqlite3.connect(self.app.home / "albedo.sqlite", timeout=10)

    def wait_expiry(self, session, input_id, status):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.receipt(session, input_id)
            except urllib.error.HTTPError as failure:
                self.assertEqual(failure.code, status)
                return
            time.sleep(0.05)
        self.fail("terminal receipt did not expire")

    def delete(self, session):
        with self.app.api(f"/sessions/{session}?view=configuration") as response:
            validator = response.getheader("ETag")
            response.read()
        with self.app.api(
            f"/sessions/{session}?view=configuration",
            method="DELETE",
            headers={"If-Match": validator},
        ) as response:
            outcome = json.load(response)
            self.assertEqual(outcome["state"], "complete", outcome)

    def test_terminal_receipt_expiry_prevents_reexecution(self):
        session = self.app.session()
        input_id = operation_id()
        intent = {"kind": "message", "text": "terminal input"}
        self.put_input(session, input_id, intent)
        self.committed(session, input_id)
        self.app.idle(session)
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        aged_id = operation_id(old_time)
        with self.database() as database:
            database.execute(
                "UPDATE operations SET id=?,created_at=?,terminal_at=? WHERE id=?",
                (aged_id, old_time, old_time, input_id),
            )
        self.wait_expiry(session, aged_id, 410)
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.put_input(session, aged_id, intent)
        self.assertEqual(failure.exception.code, 410)
        self.assertEqual(json.load(failure.exception)["code"], "identity_expired")
        self.assertEqual(len(self.users(session)), 1)
        self.assertEqual(len(self.provider.requests), 1)
        with self.app.api(f"/sessions/{session}") as response:
            self.assertIsNotNone(json.load(response)["creation"])

    def test_aged_pending_receipt_remains_recoverable_after_restart(self):
        session = self.app.session()
        input_id = operation_id()
        intent = {"kind": "message", "text": "old pending input"}
        with self.database() as database:
            database.execute(
                "CREATE TRIGGER hold_pending BEFORE INSERT ON transcript WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        accepted = self.put_input(session, input_id, intent)
        self.assertEqual(self.receipt(session, input_id)["delivery"], "pending")
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        aged_id = operation_id(old_time)

        def age_pending(_):
            with self.database() as database:
                payload = database.execute(
                    "SELECT payload FROM pending_inputs WHERE operation_id=?",
                    (input_id,),
                ).fetchone()[0]
                payload = payload.replace(input_id.encode(), aged_id.encode())
                response = database.execute(
                    "SELECT response FROM operations WHERE id=?", (input_id,)
                ).fetchone()[0]
                response = response.replace(input_id, aged_id)
                database.execute(
                    "UPDATE operations SET id=?,created_at=?,response=? WHERE id=?",
                    (aged_id, old_time, response, input_id),
                )
                database.execute(
                    "UPDATE pending_inputs SET operation_id=?,payload=?,accepted_at=? WHERE operation_id=?",
                    (aged_id, payload, old_time, input_id),
                )

        self.app.restart(crash=True, prepare=age_pending)
        self.assertEqual(self.receipt(session, aged_id)["delivery"], "pending")
        self.assertEqual(
            self.put_input(session, aged_id, intent)["acceptance_order"],
            accepted["acceptance_order"],
        )
        with self.database() as database:
            database.execute("DROP TRIGGER hold_pending")
        self.committed(session, aged_id)
        self.app.idle(session)
        self.app.restart(crash=True)
        self.assertEqual(self.receipt(session, aged_id)["delivery"], "committed")
        self.assertEqual(
            [entry["input_id"] for entry in self.users(session)], [aged_id]
        )

    def test_unfinished_consumed_turn_does_not_start_receipt_retention(self):
        session = self.app.session()
        completed_id = operation_id()
        self.put_input(
            session, completed_id, {"kind": "message", "text": "completed control"}
        )
        self.committed(session, completed_id)
        self.app.idle(session)
        started, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)

        def held_reply(_):
            started.set()
            if not release.wait(30):
                raise AssertionError("unfinished turn was not released")
            return text("finished held turn")

        self.provider.script = held_reply
        held_id = operation_id()
        self.put_input(
            session, held_id, {"kind": "message", "text": "unfinished control"}
        )
        self.assertTrue(started.wait(10))
        self.assertEqual(self.receipt(session, held_id)["delivery"], "committed")
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        with self.database() as database:
            database.execute(
                "UPDATE operations SET terminal_at=? WHERE id=?",
                (old_time, completed_id),
            )
            database.execute(
                "UPDATE operations SET created_at=? WHERE id=?", (old_time, held_id)
            )
            self.assertIsNone(
                database.execute(
                    "SELECT terminal_at FROM operations WHERE id=?", (held_id,)
                ).fetchone()[0]
            )
        # Expiration of the completed control proves the real prune pass ran.
        self.wait_expiry(session, completed_id, 404)
        self.assertEqual(self.receipt(session, held_id)["turn"]["state"], "running")
        with self.database() as database:
            self.assertIsNone(
                database.execute(
                    "SELECT terminal_at FROM operations WHERE id=?", (held_id,)
                ).fetchone()[0]
            )
        release.set()
        self.app.idle(session)
        self.assertEqual(self.receipt(session, held_id)["turn"]["state"], "completed")
        with self.database() as database:
            self.assertGreater(
                database.execute(
                    "SELECT terminal_at FROM operations WHERE id=?", (held_id,)
                ).fetchone()[0],
                old_time,
            )

    def test_deleted_session_keeps_creation_and_cancelled_input_receipts(self):
        session = self.app.session()
        with self.app.api(f"/sessions/{session}") as response:
            creation = json.load(response)["creation"]
        with self.database() as database:
            database.execute(
                "CREATE TRIGGER hold_pending BEFORE INSERT ON transcript WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        input_id = operation_id()
        intent = {"kind": "message", "text": "cancel when deleted"}
        accepted = self.put_input(session, input_id, intent)
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.receipt(session, input_id)["blocking_reason"]:
                break
            time.sleep(0.03)
        else:
            self.fail("input did not reach blocked consumption")
        self.delete(session)
        self.assertEqual(self.receipt(session, input_id)["delivery"], "cancelled")
        self.app.restart(crash=True)
        with self.assertRaises(urllib.error.HTTPError) as lookup:
            self.app.api(f"/sessions/{session}")
        self.assertEqual(lookup.exception.code, 410)
        self.assertEqual(json.load(lookup.exception)["decision"]["creation"], creation)
        with self.assertRaises(urllib.error.HTTPError) as retry_creation:
            self.app.api(
                f"/sessions/{session}",
                creation["submitted"],
                method="PUT",
                headers={"If-None-Match": "*"},
            )
        self.assertEqual(retry_creation.exception.code, 410)
        replay = self.put_input(session, input_id, intent)
        self.assertEqual(replay["acceptance_order"], accepted["acceptance_order"])
        self.assertEqual(replay["delivery"], "cancelled")
        with self.database() as database:
            self.assertEqual(
                database.execute("SELECT count(*) FROM sessions").fetchone()[0], 0
            )
            self.assertEqual(
                database.execute("SELECT count(*) FROM pending_inputs").fetchone()[0], 0
            )

    def test_continuation_marker_survives_receipt_pruning_and_restart(self):
        session = self.app.session()
        self.app.prompt(session, "start").close()
        self.app.idle(session)
        input_id = operation_id()
        self.put_input(session, input_id, {"kind": "continue"})
        self.committed(session, input_id)
        self.app.idle(session)
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        with self.database() as database:
            database.execute(
                "UPDATE operations SET terminal_at=? WHERE id=?", (old_time, input_id)
            )
        self.wait_expiry(session, input_id, 404)
        self.app.restart(crash=True)
        with self.database() as database:
            marker = database.execute(
                "SELECT session,seq FROM continuation_markers WHERE operation_id=?",
                (input_id,),
            ).fetchall()
            self.assertEqual(len(marker), 1)
            self.assertEqual(marker[0][0], session)
            self.assertGreater(marker[0][1], 0)
        self.assertEqual(len(self.users(session)), 1)
        self.assertEqual(len(self.provider.requests), 2)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            with self.app.api(f"/sessions/{session}?tail=0") as response:
                kernel = json.load(response)["kernel"]
            if kernel["state"] == "attached":
                break
            time.sleep(0.05)
        else:
            self.fail(
                f"the retained kernel did not finish reattachment before deletion: {kernel}"
            )
        self.delete(session)
        with self.database() as database:
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM continuation_markers WHERE operation_id=?",
                    (input_id,),
                ).fetchone()[0],
                0,
            )
