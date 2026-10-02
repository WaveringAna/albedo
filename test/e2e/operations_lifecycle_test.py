"""Admission and consumption failures must leave recoverable, atomic decisions."""

import base64
import json
import random
import struct
import zlib
import sqlite3
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text
from image_limits_test import png


SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000


class OperationLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda request: text("done"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def database(self):
        return sqlite3.connect(self.app.home / "albedo.sqlite", timeout=10)

    def post(self, path, request):
        with self.app.api(path, request) as response:
            return json.load(response)

    def receipt(self, operation):
        with self.app.api(f"/operations/{operation}") as response:
            return json.load(response)

    def delivered(self, operation):
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            receipt = self.receipt(operation)
            if receipt["deliveryStatus"] == "committed":
                return receipt
            time.sleep(0.05)
        self.fail(f"operation was not committed: {receipt}")

    # exclusive: installs a global database trigger and counts all sessions
    @exclusive
    def test_creation_failure_rolls_back_session_and_receipt(self):
        operation = operation_id()
        request = {
            "operationId": operation,
            "workspace": str(self.app.workspace),
            "provider": self.app.profile,
        }
        with self.database() as db:
            before = db.execute("SELECT count(*) FROM sessions").fetchone()[0]
            db.execute(
                "CREATE TRIGGER fail_creation BEFORE INSERT ON sessions "
                "BEGIN SELECT RAISE(ABORT, 'fixture'); END"
            )
        with self.assertRaises(urllib.error.HTTPError):
            self.post("/sessions", request)
        with self.database() as db:
            self.assertEqual(
                db.execute("SELECT count(*) FROM sessions").fetchone()[0], before
            )
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM operations WHERE id=?", (operation,)
                ).fetchone()[0],
                0,
            )
            db.execute("DROP TRIGGER fail_creation")
        created = self.post("/sessions", request)
        self.assertEqual(self.post("/sessions", request), created)
        self.assertEqual(self.receipt(operation)["status"], "accepted")

    # exclusive: installs a global database trigger
    @exclusive
    def test_admission_failure_can_retry_original_id(self):
        session = self.app.session()
        operation = operation_id()
        request = {"operationId": operation, "content": "durable input"}
        with self.database() as db:
            db.execute(
                "CREATE TRIGGER fail_admission BEFORE INSERT ON pending_inputs "
                "BEGIN SELECT RAISE(ABORT, 'fixture'); END"
            )
        with self.assertRaises(urllib.error.HTTPError):
            self.post(f"/sessions/{session}/events", request)
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM operations WHERE id=?", (operation,)
                ).fetchone()[0],
                0,
            )
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM transcript WHERE session=?", (session,)
                ).fetchone()[0],
                0,
            )
            db.execute("DROP TRIGGER fail_admission")
        accepted = self.post(f"/sessions/{session}/events", request)
        self.delivered(operation)
        self.assertEqual(self.post(f"/sessions/{session}/events", request), accepted)
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM transcript WHERE session=? AND row_class='user'",
                    (session,),
                ).fetchone()[0],
                1,
            )

    # exclusive: installs a global database trigger and restarts the daemon
    @exclusive
    def test_consumption_failure_keeps_pending_input_until_storage_recovers(self):
        session = self.app.session()
        operation = operation_id()
        image = png(2, 2)
        request = {
            "operationId": operation,
            "content": "recover after storage repair",
            "image": {
                "mimeType": "image/png",
                "data": base64.b64encode(image).decode(),
                "width": 2,
                "height": 2,
                "bytes": len(image),
            },
        }
        with self.database() as db:
            db.execute(
                "CREATE TRIGGER fail_consumption BEFORE INSERT ON submission_events "
                "BEGIN SELECT RAISE(ABORT, 'fixture'); END"
            )
        accepted = self.post(f"/sessions/{session}/events", request)
        receipt = self.receipt(operation)
        self.assertEqual(receipt["status"], "accepted")
        self.assertEqual(receipt["deliveryStatus"], "pending")
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM pending_inputs WHERE operation_id=?",
                    (operation,),
                ).fetchone()[0],
                1,
            )
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM transcript WHERE session=?", (session,)
                ).fetchone()[0],
                0,
            )
            self.assertEqual(db.execute("SELECT count(*) FROM images").fetchone()[0], 0)
            self.assertEqual(
                db.execute("SELECT count(*) FROM submission_events").fetchone()[0], 0
            )
        self.app.restart(crash=True)
        self.assertEqual(self.post(f"/sessions/{session}/events", request), accepted)
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "pending")
        with self.database() as db:
            db.execute("DROP TRIGGER fail_consumption")
        self.delivered(operation)
        self.app.idle(session)
        self.app.restart(crash=True)
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "committed")
        with self.assertRaises(urllib.error.HTTPError) as conflict:
            self.post(
                f"/sessions/{session}/events",
                {**request, "content": "changed after restart"},
            )
        self.assertEqual(conflict.exception.code, 409)
        self.assertEqual(json.load(conflict.exception)["code"], "operation_conflict")
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM transcript WHERE session=? AND row_class='user'",
                    (session,),
                ).fetchone()[0],
                1,
            )

    # exclusive: measures global storage growth and restarts the daemon
    @exclusive
    def test_repeated_image_commits_grow_only_compact_metadata(self):
        session = self.app.session()
        width, height = 256, 256

        def chunk(kind, data):
            body = kind + data
            return (
                struct.pack(">I", len(data))
                + body
                + struct.pack(">I", zlib.crc32(body))
            )

        pixels = random.Random(1).randbytes(width * height * 3)
        rows = b"".join(
            b"\x00" + pixels[start : start + width * 3]
            for start in range(0, len(pixels), width * 3)
        )
        image = (
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows))
            + chunk(b"IEND", b"")
        )
        attachment = {
            "mimeType": "image/png",
            "data": base64.b64encode(image).decode(),
            "width": width,
            "height": height,
            "bytes": len(image),
        }

        def durable_bytes():
            with self.database() as db:
                return sum(
                    db.execute(
                        f"SELECT coalesce(sum(length({column})),0) FROM {table}"
                    ).fetchone()[0]
                    for table, column in (
                        ("images", "data"),
                        ("transcript", "payload"),
                        ("submission_events", "payload"),
                        ("continuation_markers", "payload"),
                        ("pending_inputs", "payload"),
                        ("operations", "response"),
                    )
                )

        operations = []
        echoes = []
        sizes = []
        for index in range(3):
            operation = operation_id()
            echo = f"image-echo-{index}"
            operations.append(operation)
            echoes.append(echo)
            self.post(
                f"/sessions/{session}/events",
                {
                    "operationId": operation,
                    "clientId": echo,
                    "content": "same image",
                    "image": attachment,
                },
            )
            self.delivered(operation)
            self.app.idle(session)
            sizes.append(durable_bytes())
        self.assertLess(sizes[2] - sizes[0], len(image))
        self.app.restart(crash=True)
        users = [
            event for event in self.app.events(session) if event.get("type") == "user"
        ]
        self.assertEqual([event["operationId"] for event in users], operations)
        self.assertEqual([event["clientId"] for event in users], echoes)
        self.assertEqual(
            [event["image"] for event in users],
            [{key: value for key, value in attachment.items() if key != "data"}] * 3,
        )

    def test_expired_and_future_ids_cannot_create_work(self):
        now = int(time.time() * 1000)
        for timestamp, status, code in (
            (now - SEVEN_DAYS_MS - 10000, 410, "operation_expired"),
            (now + 6 * 60 * 1000, 400, "operation_future"),
        ):
            operation = operation_id(timestamp)
            request = {"operationId": operation, "workspace": str(self.app.workspace)}
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.post("/sessions", request)
            self.assertEqual(failure.exception.code, status)
            self.assertEqual(json.load(failure.exception)["code"], code)
            with self.database() as db:
                self.assertEqual(
                    db.execute(
                        "SELECT count(*) FROM operations WHERE id=?", (operation,)
                    ).fetchone()[0],
                    0,
                )

    # exclusive: restarts the daemon and counts all sessions
    @exclusive
    def test_rejected_creation_replays_after_workspace_is_repaired(self):
        operation = operation_id()
        workspace = self.app.workspace / "missing"
        request = {
            "operationId": operation,
            "workspace": str(workspace),
            "provider": self.app.profile,
        }
        with self.assertRaises(urllib.error.HTTPError) as original:
            self.post("/sessions", request)
        error = json.load(original.exception)
        self.assertEqual(self.receipt(operation)["status"], "rejected")
        workspace.mkdir()
        self.app.restart(crash=True)
        with self.assertRaises(urllib.error.HTTPError) as repeated:
            self.post("/sessions", request)
        self.assertEqual(repeated.exception.code, original.exception.code)
        self.assertEqual(json.load(repeated.exception), error)
        with self.database() as db:
            self.assertEqual(
                db.execute("SELECT count(*) FROM sessions").fetchone()[0], 0
            )

    # exclusive: installs global database triggers and restarts the daemon
    @exclusive
    def test_failed_interrupt_does_not_discard_pending_input(self):
        session = self.app.session()
        operation = operation_id()
        request = {
            "operationId": operation,
            "content": "keep until cancellation commits",
        }
        with self.database() as db:
            db.execute(
                "CREATE TRIGGER hold_consumption BEFORE INSERT ON transcript "
                "WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT, 'fixture'); END"
            )
        self.post(f"/sessions/{session}/events", request)
        with self.database() as db:
            db.execute(
                "CREATE TRIGGER fail_cancellation BEFORE UPDATE ON operations "
                "WHEN NEW.delivery='cancelled' BEGIN SELECT RAISE(ABORT, 'fixture'); END"
            )
        result = self.post(f"/sessions/{session}/interrupt", {})
        self.assertFalse(result["interrupted"])
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "pending")
        with self.database() as db:
            db.execute("DROP TRIGGER fail_cancellation")
        result = self.post(f"/sessions/{session}/interrupt", {})
        self.assertTrue(result["interrupted"])
        self.app.restart(crash=True)
        self.assertEqual(self.receipt(operation)["deliveryStatus"], "cancelled")
        with self.database() as db:
            self.assertEqual(
                db.execute(
                    "SELECT count(*) FROM pending_inputs WHERE operation_id=?",
                    (operation,),
                ).fetchone()[0],
                0,
            )
