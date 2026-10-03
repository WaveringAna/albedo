"""Admission and consumption failures leave recoverable, atomic identified decisions."""

import base64
import json
import random
import struct
import zlib
import sqlite3
import time
import urllib.error

from harness import exclusive, operation_id
from image_limits_test import png
from operations_test import InputScenario

SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000


class OperationLifecycleTests(InputScenario):
    def database(self):
        return sqlite3.connect(self.app.home / "albedo.sqlite", timeout=10)

    def create(self, session_id, intent):
        with self.app.api(
            f"/sessions/{session_id}",
            intent,
            method="PUT",
            headers={"If-None-Match": "*"},
        ) as response:
            return json.load(response)

    @exclusive
    def test_creation_failure_rolls_back_session_and_receipt(self):
        session_id = operation_id()
        intent = {
            "kind": "new",
            "workspace": str(self.app.workspace),
            "provider_profile": self.app.profile,
        }
        with self.database() as database:
            before = database.execute("SELECT count(*) FROM sessions").fetchone()[0]
            database.execute(
                "CREATE TRIGGER fail_creation BEFORE INSERT ON sessions BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        with self.assertRaises(urllib.error.HTTPError):
            self.create(session_id, intent)
        with self.database() as database:
            self.assertEqual(
                database.execute("SELECT count(*) FROM sessions").fetchone()[0], before
            )
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM operations WHERE id=?", (session_id,)
                ).fetchone()[0],
                0,
            )
            database.execute("DROP TRIGGER fail_creation")
        created = self.create(session_id, intent)
        self.assertEqual(created["id"], session_id)
        with self.app.api(f"/sessions/{session_id}") as response:
            self.assertEqual(json.load(response)["creation"], created["creation"])

    @exclusive
    def test_admission_failure_can_retry_original_id(self):
        session = self.app.session()
        input_id = operation_id()
        intent = {"kind": "message", "text": "durable input"}
        with self.database() as database:
            database.execute(
                "CREATE TRIGGER fail_admission BEFORE INSERT ON pending_inputs BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        with self.assertRaises(urllib.error.HTTPError):
            self.put_input(session, input_id, intent)
        with self.database() as database:
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM operations WHERE id=?", (input_id,)
                ).fetchone()[0],
                0,
            )
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM transcript WHERE session=?", (session,)
                ).fetchone()[0],
                0,
            )
            database.execute("DROP TRIGGER fail_admission")
        accepted = self.put_input(session, input_id, intent)
        self.committed(session, input_id)
        self.app.idle(session)
        self.assertEqual(
            self.put_input(session, input_id, intent)["acceptance_order"],
            accepted["acceptance_order"],
        )
        self.assertEqual(
            [entry["input_id"] for entry in self.users(session)], [input_id]
        )

    @exclusive
    def test_consumption_failure_keeps_pending_input_until_storage_recovers(self):
        session = self.app.session()
        input_id = operation_id()
        intent = {
            "kind": "message",
            "text": "recover after storage repair",
            "image": {
                "mime_type": "image/png",
                "data": base64.b64encode(png(2, 2)).decode(),
            },
        }
        with self.database() as database:
            database.execute(
                "CREATE TRIGGER fail_consumption BEFORE INSERT ON submission_events BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        accepted = self.put_input(session, input_id, intent)
        self.assertEqual(accepted["admission"], "accepted")
        self.assertEqual(self.receipt(session, input_id)["delivery"], "pending")
        with self.database() as database:
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM pending_inputs WHERE operation_id=?",
                    (input_id,),
                ).fetchone()[0],
                1,
            )
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM transcript WHERE session=?", (session,)
                ).fetchone()[0],
                0,
            )
            self.assertEqual(
                database.execute("SELECT count(*) FROM images").fetchone()[0], 0
            )
            self.assertEqual(
                database.execute("SELECT count(*) FROM submission_events").fetchone()[
                    0
                ],
                0,
            )
        self.app.restart(crash=True)
        self.assertEqual(
            self.put_input(session, input_id, intent)["acceptance_order"],
            accepted["acceptance_order"],
        )
        self.assertEqual(self.receipt(session, input_id)["delivery"], "pending")
        with self.database() as database:
            database.execute("DROP TRIGGER fail_consumption")
        self.committed(session, input_id)
        self.app.idle(session)
        self.app.restart(crash=True)
        self.assertEqual(self.receipt(session, input_id)["delivery"], "committed")
        self.conflict(session, input_id, {**intent, "text": "changed after restart"})
        self.assertEqual(
            [entry["input_id"] for entry in self.users(session)], [input_id]
        )

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
            "mime_type": "image/png",
            "data": base64.b64encode(image).decode(),
        }

        def durable_bytes():
            with self.database() as database:
                return sum(
                    database.execute(
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

        inputs, sizes = [], []
        for index in range(3):
            input_id = operation_id()
            inputs.append(input_id)
            self.put_input(
                session,
                input_id,
                {
                    "kind": "message",
                    "text": "same image",
                    "client_id": f"image-echo-{index}",
                    "image": attachment,
                },
            )
            self.committed(session, input_id)
            self.app.idle(session)
            sizes.append(durable_bytes())
        self.assertLess(sizes[2] - sizes[0], len(image))
        self.app.restart(crash=True)
        users = self.users(session)
        self.assertEqual([entry["input_id"] for entry in users], inputs)
        for index, input_id in enumerate(inputs):
            self.assertEqual(
                self.receipt(session, input_id)["client_id"], f"image-echo-{index}"
            )
        metadata = [
            part["image"]
            for entry in users
            for part in entry["content"]
            if part["kind"] == "image"
        ]
        self.assertEqual(
            [
                (item["width"], item["height"], item["original_bytes"])
                for item in metadata
            ],
            [(width, height, len(image))] * 3,
        )

    def test_expired_and_future_ids_cannot_create_work(self):
        now = int(time.time() * 1000)
        for timestamp, status, code in (
            (now - SEVEN_DAYS_MS - 10000, 410, "identity_expired"),
            (now + 6 * 60 * 1000, 400, "identity_future"),
        ):
            session_id = operation_id(timestamp)
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.create(
                    session_id, {"kind": "new", "workspace": str(self.app.workspace)}
                )
            self.assertEqual(failure.exception.code, status)
            self.assertEqual(json.load(failure.exception)["code"], code)
            with self.database() as database:
                self.assertEqual(
                    database.execute(
                        "SELECT count(*) FROM operations WHERE id=?", (session_id,)
                    ).fetchone()[0],
                    0,
                )

    @exclusive
    def test_rejected_creation_replays_after_workspace_is_repaired(self):
        session_id = operation_id()
        workspace = self.app.workspace / "missing"
        intent = {
            "kind": "new",
            "workspace": str(workspace),
            "provider_profile": self.app.profile,
        }
        with self.assertRaises(urllib.error.HTTPError) as original:
            self.create(session_id, intent)
        problem = json.load(original.exception)
        with self.assertRaises(urllib.error.HTTPError) as lookup:
            self.app.api(f"/sessions/{session_id}")
        self.assertEqual(
            json.load(lookup.exception)["decision"]["admission"], "rejected"
        )
        workspace.mkdir()
        self.app.restart(crash=True)
        with self.assertRaises(urllib.error.HTTPError) as repeated:
            self.create(session_id, intent)
        self.assertEqual(repeated.exception.code, original.exception.code)
        self.assertEqual(json.load(repeated.exception), problem)
        with self.database() as database:
            self.assertEqual(
                database.execute("SELECT count(*) FROM sessions").fetchone()[0], 0
            )

    @exclusive
    def test_failed_cancellation_does_not_discard_pending_input(self):
        session = self.app.session()
        input_id = operation_id()
        with self.database() as database:
            database.execute(
                "CREATE TRIGGER hold_consumption BEFORE INSERT ON transcript WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        self.put_input(
            session,
            input_id,
            {"kind": "message", "text": "keep until cancellation commits"},
        )
        with self.database() as database:
            database.execute(
                "CREATE TRIGGER fail_cancellation BEFORE UPDATE ON operations WHEN NEW.delivery='cancelled' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        resource = f"/sessions/{session}/inputs/{input_id}/cancel"
        with self.assertRaises(urllib.error.HTTPError):
            self.app.api(resource, {})
        self.assertEqual(self.receipt(session, input_id)["delivery"], "pending")
        with self.database() as database:
            database.execute("DROP TRIGGER fail_cancellation")
        with self.app.api(resource, {}) as response:
            self.assertEqual(json.load(response)["result"], "cancelled")
        self.app.restart(crash=True)
        self.assertEqual(self.receipt(session, input_id)["delivery"], "cancelled")
        with self.database() as database:
            self.assertEqual(
                database.execute(
                    "SELECT count(*) FROM pending_inputs WHERE operation_id=?",
                    (input_id,),
                ).fetchone()[0],
                0,
            )
