"""Receipts must survive deletion and preserve aged pending work during pruning."""

import json
import sqlite3
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text

RETENTION_MS = 7 * 24 * 60 * 60 * 1000


@exclusive
class OperationRetentionTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda request: text("done"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses", prepare=self.prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def prepare(self, app):
        app.env["ALBEDO_SCHEDULE_TICK_MS"] = "50"

    def database(self):
        return sqlite3.connect(self.app.home / "albedo.sqlite", timeout=10)

    def post(self, path, request):
        with self.app.api(path, request) as response:
            return json.load(response)

    def receipt(self, operation):
        with self.app.api(f"/operations/{operation}") as response:
            return json.load(response)

    def wait_delivery(self, operation, expected):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            receipt = self.receipt(operation)
            if receipt["deliveryStatus"] == expected:
                return receipt
            time.sleep(0.05)
        self.fail(f"operation did not become {expected}: {receipt}")

    def test_terminal_receipt_expiry_prevents_reexecution(self):
        operation = operation_id()
        request = {
            "operationId": operation,
            "workspace": str(self.app.workspace),
            "provider": self.app.profile,
        }
        created = self.post("/sessions", request)
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        aged_operation = operation_id(old_time)
        with self.database() as db:
            db.execute(
                "UPDATE operations SET id=?,created_at=?,terminal_at=? WHERE id=?",
                (aged_operation, old_time, old_time, operation),
            )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.receipt(aged_operation)
            except urllib.error.HTTPError as failure:
                self.assertEqual(failure.code, 410)
                self.assertEqual(json.load(failure)["code"], "operation_expired")
                break
            time.sleep(0.05)
        else:
            self.fail("terminal receipt did not expire")
        request["operationId"] = aged_operation
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.post("/sessions", request)
        self.assertEqual(failure.exception.code, 410)
        with self.database() as db:
            self.assertEqual(
                db.execute("SELECT id FROM sessions").fetchall(), [(created["id"],)]
            )

    def test_aged_pending_receipt_remains_recoverable_after_restart(self):
        session = self.app.session()
        operation = operation_id()
        request = {"operationId": operation, "content": "old pending input"}
        with self.database() as db:
            db.execute(
                "CREATE TRIGGER hold_pending BEFORE INSERT ON transcript "
                "WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        accepted = self.post(f"/sessions/{session}/events", request)
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "pending")
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        aged_operation = operation_id(old_time)

        def age_pending(app):
            with self.database() as db:
                payload = db.execute(
                    "SELECT payload FROM pending_inputs WHERE operation_id=?",
                    (operation,),
                ).fetchone()[0]
                payload = payload.replace(operation.encode(), aged_operation.encode())
                db.execute(
                    "UPDATE operations SET id=?,created_at=? WHERE id=?",
                    (aged_operation, old_time, operation),
                )
                db.execute(
                    "UPDATE pending_inputs SET operation_id=?,payload=?,accepted_at=? "
                    "WHERE operation_id=?",
                    (aged_operation, payload, old_time, operation),
                )

        self.app.restart(crash=True, prepare=age_pending)
        request["operationId"] = aged_operation
        accepted["operationId"] = aged_operation
        # Admission response is persisted; the fixture also updates its action ID.
        with self.database() as db:
            response = db.execute(
                "SELECT response FROM operations WHERE id=?", (aged_operation,)
            ).fetchone()[0]
            response = response.replace(operation, aged_operation)
            db.execute(
                "UPDATE operations SET response=? WHERE id=?",
                (response, aged_operation),
            )
        self.assertEqual(self.receipt(aged_operation)["deliveryStatus"], "pending")
        self.assertEqual(self.post(f"/sessions/{session}/events", request), accepted)
        with self.database() as db:
            db.execute("DROP TRIGGER hold_pending")
        self.wait_delivery(aged_operation, "committed")
        self.app.idle(session)
        self.app.restart(crash=True)
        self.assertEqual(self.receipt(aged_operation)["deliveryStatus"], "committed")
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM transcript WHERE session=? AND row_class='user'",
                    (session,),
                ).fetchone()[0],
                1,
            )

    def test_deleted_session_keeps_creation_and_cancelled_input_receipts(self):
        creation = operation_id()
        create_request = {
            "operationId": creation,
            "workspace": str(self.app.workspace),
            "provider": self.app.profile,
        }
        created = self.post("/sessions", create_request)
        session = created["id"]
        with self.database() as db:
            db.execute(
                "CREATE TRIGGER hold_pending BEFORE INSERT ON transcript "
                "WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        operation = operation_id()
        request = {"operationId": operation, "content": "cancel when deleted"}
        accepted = self.post(f"/sessions/{session}/events", request)
        self.app.idle(session)
        with self.app.api(f"/sessions/{session}", method="DELETE") as response:
            json.load(response)
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "cancelled")
        self.app.restart(crash=True)
        self.assertEqual(self.post("/sessions", create_request), created)
        self.assertEqual(self.receipt(creation)["target"], session)
        self.assertEqual(self.post(f"/sessions/{session}/events", request), accepted)
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "cancelled")
        with self.database() as db:
            self.assertEqual(
                db.execute("SELECT count(*) FROM sessions").fetchone()[0], 0
            )
            self.assertEqual(
                db.execute("SELECT count(*) FROM pending_inputs").fetchone()[0], 0
            )

    def test_continuation_marker_survives_receipt_pruning_and_restart(self):
        session = self.app.session()
        self.app.prompt(session, "start").close()
        self.app.idle(session)
        operation = operation_id()
        request = {"operationId": operation, "type": "continue"}
        self.post(f"/sessions/{session}/events", request)
        self.wait_delivery(operation, "committed")
        self.app.idle(session)
        old_time = int(time.time() * 1000) - RETENTION_MS - 10000
        with self.database() as db:
            db.execute(
                "UPDATE operations SET terminal_at=? WHERE id=?",
                (old_time, operation),
            )
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                self.receipt(operation)
            except urllib.error.HTTPError as failure:
                self.assertEqual(failure.code, 404)
                break
            time.sleep(0.05)
        else:
            self.fail("terminal receipt did not expire")
        self.app.restart(crash=True)
        with self.database() as db:
            marker = db.execute(
                "SELECT session,seq FROM continuation_markers WHERE operation_id=?",
                (operation,),
            ).fetchall()
            self.assertEqual(len(marker), 1)
            self.assertEqual(marker[0][0], session)
            self.assertGreater(marker[0][1], 0)
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM transcript WHERE session=? AND row_class='user'",
                    (session,),
                ).fetchone()[0],
                1,
            )
        self.assertEqual(len(self.provider.requests), 2)
        with self.app.api(f"/sessions/{session}", method="DELETE") as response:
            json.load(response)
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM continuation_markers WHERE operation_id=?",
                    (operation,),
                ).fetchone()[0],
                0,
            )
