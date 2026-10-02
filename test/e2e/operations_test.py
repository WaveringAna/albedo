"""Retrying an intended action must replay its original durable admission."""

from concurrent.futures import ThreadPoolExecutor
import base64
import json
import os
from pathlib import Path
import shlex
import shutil
import sqlite3
import threading
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, operation_id, text
from image_limits_test import png


class OperationsTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda request: text("done"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def post(self, path, request):
        with self.app.api(path, request) as response:
            return json.load(response)

    def receipt(self, operation):
        with self.app.api(f"/operations/{operation}") as response:
            return json.load(response)

    def duplicates(self, path, request):
        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(lambda _: self.post(path, request), range(6)))
        self.assertTrue(all(result == results[0] for result in results))
        return results[0]

    def committed(self, operation):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            receipt = self.receipt(operation)
            if receipt["deliveryStatus"] == "committed":
                return receipt
            time.sleep(0.03)
        self.fail(f"operation remained pending: {receipt}")

    def conflict(self, path, request):
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.post(path, request)
        self.assertEqual(failure.exception.code, 409)
        self.assertEqual(json.load(failure.exception)["code"], "operation_conflict")

    def test_concurrent_creation_duplicates_and_changed_defaults(self):
        operation = operation_id()
        request = {
            "operationId": operation,
            "workspace": str(self.app.workspace),
            "provider": self.app.profile,
        }
        created = self.duplicates("/sessions", request)
        self.assertEqual(self.receipt(operation)["result"], created)
        self.assertEqual(self.post("/sessions", {**request, "model": ""}), created)
        self.conflict("/sessions", {**request, "model": "other-model"})
        with self.app.api("/sessions") as response:
            matches = [row for row in json.load(response) if row["id"] == created["id"]]
        self.assertEqual(len(matches), 1)

    def test_submission_identity_and_durable_echo(self):
        session = self.app.session()
        path = f"/sessions/{session}/events"
        operation = operation_id()
        request = {
            "operationId": operation,
            "content": "same message",
            "clientId": "first",
        }
        accepted = self.duplicates(path, request)
        self.assertEqual(self.post(path, {**request, "clientId": "retry"}), accepted)
        self.committed(operation)
        self.app.idle(session)
        self.conflict(path, {**request, "content": "changed message"})
        other = self.app.session()
        self.conflict(f"/sessions/{other}/events", request)
        self.conflict(path, {"operationId": operation, "type": "continue"})
        second = operation_id()
        self.post(path, {**request, "operationId": second, "clientId": "second"})
        self.committed(second)
        self.app.idle(session)
        events = self.app.events(session)
        users = [event for event in events if event.get("type") == "user"]
        self.assertEqual([event["operationId"] for event in users], [operation, second])
        self.assertEqual([event["clientId"] for event in users], ["first", "second"])
        self.assertEqual([event["text"] for event in users], ["same message"] * 2)

    def test_image_duplicates_and_changed_image_conflict(self):
        session = self.app.session()
        payload = png(2, 2)
        image = {
            "mimeType": "image/png",
            "data": base64.b64encode(payload).decode(),
            "width": 2,
            "height": 2,
            "bytes": len(payload),
        }
        operation = operation_id()
        request = {"operationId": operation, "content": "inspect image", "image": image}
        self.duplicates(f"/sessions/{session}/events", request)
        self.committed(operation)
        self.app.idle(session)
        changed = png(3, 2)
        self.conflict(
            f"/sessions/{session}/events",
            {
                **request,
                "image": {
                    **image,
                    "data": base64.b64encode(changed).decode(),
                    "width": 3,
                    "bytes": len(changed),
                },
            },
        )
        users = [
            event for event in self.app.events(session) if event.get("type") == "user"
        ]
        self.assertEqual(len(users), 1)
        self.assertEqual(users[0]["operationId"], operation)
        self.assertEqual(users[0]["image"]["width"], 2)

    def test_continue_is_one_admission_without_an_extra_user_row(self):
        session = self.app.session()
        self.app.prompt(session, "start").close()
        self.app.idle(session)
        operation = operation_id()
        request = {"operationId": operation, "type": "continue"}
        accepted = self.duplicates(f"/sessions/{session}/events", request)
        self.committed(operation)
        self.app.idle(session)
        self.assertEqual(self.receipt(operation)["result"], accepted)
        with sqlite3.connect(self.app.home / "albedo.sqlite") as database:
            count = database.execute(
                "SELECT count(*) FROM transcript WHERE session=? AND row_class='user'",
                (session,),
            ).fetchone()[0]
        self.assertEqual(count, 1)
        self.assertEqual(len(self.provider.requests), 2)

    def test_skill_admission_uses_resolved_content_once(self):
        skill = self.app.workspace / ".agents/skills/retry-skill/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: retry-skill\ndescription: test activation\n---\nKeep this original instruction.\n"
        )
        session = self.app.session()
        operation = operation_id()
        request = {
            "operationId": operation,
            "type": "skill",
            "name": "/retry-skill",
            "arguments": " do this ",
        }
        accepted = self.duplicates(f"/sessions/{session}/events", request)
        self.committed(operation)
        self.app.idle(session)
        skill.unlink()
        self.assertEqual(self.post(f"/sessions/{session}/events", request), accepted)
        self.conflict(f"/sessions/{session}/events", {**request, "arguments": "other"})
        serialized = json.dumps(self.provider.requests)
        self.assertIn("Keep this original instruction.", serialized)
        users = [
            event for event in self.app.events(session) if event.get("type") == "user"
        ]
        self.assertEqual([event["text"] for event in users], ["/retry-skill do this"])
        self.assertEqual([event["operationId"] for event in users], [operation])


@exclusive
class WaitingOperationsTests(unittest.TestCase):
    post = OperationsTests.post
    receipt = OperationsTests.receipt
    committed = OperationsTests.committed

    def setUp(self):
        self.gate = threading.Event()
        self.started = threading.Event()
        self.first = True

        def reply(request):
            if self.first:
                self.first = False
                self.started.set()
                self.gate.wait(40)
            return text("done")

        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)
        self.addCleanup(self.gate.set)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_full_queue_duplicate_bypasses_limit_and_interrupt_cancels(self):
        session = self.app.session()
        self.app.prompt(session, "hold active generation").close()
        self.assertTrue(self.started.wait(10))
        requests = [
            {"operationId": operation_id(), "content": f"waiting {index}"}
            for index in range(32)
        ]
        path = f"/sessions/{session}/events"
        results = [self.post(path, request) for request in requests]
        self.assertTrue(all(result["queued"] for result in results))
        self.assertEqual(self.post(path, requests[0]), results[0])
        with self.assertRaises(urllib.error.HTTPError):
            self.post(
                path, {"operationId": operation_id(), "content": "queue overflow"}
            )
        self.post(f"/sessions/{session}/interrupt", {})
        self.gate.set()
        self.app.idle(session)
        self.app.restart(crash=True)
        for request, result in zip(requests, results):
            self.assertEqual(
                self.receipt(request["operationId"])["deliveryStatus"], "cancelled"
            )
            self.assertEqual(self.post(path, request), result)

    def test_crash_recovers_order_images_and_resolved_skill_content(self):
        skill = self.app.workspace / ".agents/skills/retry-skill/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: retry-skill\ndescription: test activation\n---\nOriginal saved instructions.\n"
        )
        session = self.app.session()
        self.app.prompt(session, "hold active generation").close()
        self.assertTrue(self.started.wait(10))
        image = png(2, 2)
        requests = [
            {"operationId": operation_id(), "content": "first waiting"},
            {
                "operationId": operation_id(),
                "content": "second image",
                "image": {
                    "mimeType": "image/png",
                    "data": base64.b64encode(image).decode(),
                    "width": 2,
                    "height": 2,
                    "bytes": len(image),
                },
            },
            {
                "operationId": operation_id(),
                "type": "skill",
                "name": "/retry-skill",
                "arguments": "saved arguments",
            },
        ]
        path = f"/sessions/{session}/events"
        results = [self.post(path, request) for request in requests]
        self.assertTrue(
            all(
                self.receipt(request["operationId"])["deliveryStatus"] == "pending"
                for request in requests
            )
        )
        skill.unlink()
        self.app.restart(crash=True)
        self.gate.set()
        for request in requests:
            self.committed(request["operationId"])
        self.app.idle(session)
        self.app.restart(crash=True)
        for request, result in zip(requests, results):
            self.assertEqual(self.post(path, request), result)
        users = [
            event
            for event in self.app.events(session)
            if event.get("operationId")
            in {request["operationId"] for request in requests}
        ]
        self.assertEqual(
            [event["operationId"] for event in users],
            [request["operationId"] for request in requests],
        )
        self.assertEqual(
            [event["text"] for event in users],
            ["first waiting", "second image", "/retry-skill saved arguments"],
        )
        self.assertEqual(users[1]["image"]["width"], 2)
        self.assertIn(
            "Original saved instructions.", json.dumps(self.provider.requests)
        )


@exclusive
class BlockedOperationsTests(unittest.TestCase):
    app: Albedo
    setUp = OperationsTests.setUp
    post = OperationsTests.post
    receipt = OperationsTests.receipt
    committed = OperationsTests.committed

    def test_full_blocked_queue_survives_restart_and_replays_rejection(self):
        session = self.app.session()
        path = f"/sessions/{session}/events"
        requests = [
            {"operationId": operation_id(), "content": f"blocked {index}"}
            for index in range(32)
        ]
        with sqlite3.connect(self.app.home / "albedo.sqlite") as database:
            database.execute(
                "CREATE TRIGGER hold_inputs BEFORE INSERT ON transcript "
                "WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        results = [self.post(path, request) for request in requests]
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.receipt(requests[0]["operationId"])["blockingReason"]:
                break
            time.sleep(0.03)
        else:
            self.fail("waiting inputs were never blocked")
        self.assertFalse(self.app.idle(session)["running"])
        self.assertEqual(self.post(path, requests[0]), results[0])
        rejected = {"operationId": operation_id(), "content": "blocked overflow"}
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.post(path, rejected)
        self.assertEqual(failure.exception.code, 409)
        rejection = json.load(failure.exception)
        self.assertEqual(self.receipt(rejected["operationId"])["status"], "rejected")

        self.app.restart(crash=True)
        self.assertEqual(self.post(path, requests[-1]), results[-1])
        with self.assertRaises(urllib.error.HTTPError) as restored_full:
            self.post(path, {"operationId": operation_id(), "type": "continue"})
        self.assertEqual(restored_full.exception.code, 409)
        with sqlite3.connect(self.app.home / "albedo.sqlite") as database:
            database.execute("DROP TRIGGER hold_inputs")
        for request in requests:
            self.committed(request["operationId"])
        self.app.idle(session)
        users = [
            event for event in self.app.events(session) if event.get("type") == "user"
        ]
        self.assertEqual(
            [event["operationId"] for event in users],
            [request["operationId"] for request in requests],
        )
        self.assertEqual(
            [event["text"] for event in users],
            [request["content"] for request in requests],
        )
        with self.assertRaises(urllib.error.HTTPError) as replay:
            self.post(path, rejected)
        self.assertEqual(replay.exception.code, 409)
        self.assertEqual(json.load(replay.exception), rejection)


@exclusive
class PreparingOperationsTests(unittest.TestCase):
    opened: Path
    release: Path
    post = OperationsTests.post
    receipt = OperationsTests.receipt
    committed = OperationsTests.committed

    def setUp(self):
        provider = Provider(lambda request: text("done"))
        self.addCleanup(provider.close)

        def prepare(app):
            self.opened = app.root / "kernel-opening"
            self.release = app.root / "kernel-release"
            commands = app.root / "kernel-commands"
            commands.mkdir()
            executable = shutil.which("python3")
            self.assertIsNotNone(executable)
            wrapper = commands / "python3"
            wrapper.write_text(
                "#!/bin/sh\n"
                + 'case "$*" in *albedo_kernel.py*)\n'
                + "touch "
                + shlex.quote(str(self.opened))
                + "\n"
                + "while [ ! -e "
                + shlex.quote(str(self.release))
                + " ]; do sleep 0.05; done\n"
                + ";; esac\nexec "
                + shlex.quote(str(executable))
                + ' "$@"\n'
            )
            wrapper.chmod(0o755)
            app.env["PATH"] = str(commands) + os.pathsep + app.env["PATH"]

        self.app = Albedo(provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_kernel_preparation_admission_survives_restart(self):
        session = self.app.session()
        request = {
            "operationId": operation_id(),
            "content": "stored while kernel opens",
        }
        accepted = self.post(f"/sessions/{session}/events", request)
        deadline = time.monotonic() + 10
        while not self.opened.exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        self.assertTrue(self.opened.exists())
        self.assertEqual(
            self.receipt(request["operationId"])["deliveryStatus"], "pending"
        )
        self.app.restart(crash=True, prepare=lambda app: self.release.touch())
        self.assertEqual(self.post(f"/sessions/{session}/events", request), accepted)
        self.committed(request["operationId"])
        self.app.idle(session)
        users = [
            event
            for event in self.app.events(session)
            if event.get("operationId") == request["operationId"]
        ]
        self.assertEqual(len(users), 1)

    def test_full_kernel_opening_queue_delivers_once_and_replays_rejection(self):
        session = self.app.session()
        path = f"/sessions/{session}/events"
        requests = [
            {"operationId": operation_id(), "content": f"opening {index}"}
            for index in range(32)
        ]
        results = [self.post(path, request) for request in requests]
        deadline = time.monotonic() + 10
        while not self.opened.exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        self.assertTrue(self.opened.exists())
        self.assertEqual(self.post(path, requests[0]), results[0])
        rejected = {"operationId": operation_id(), "type": "continue"}
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.post(path, rejected)
        self.assertEqual(failure.exception.code, 409)
        rejection = json.load(failure.exception)
        self.assertEqual(self.receipt(rejected["operationId"])["status"], "rejected")
        self.release.touch()
        for request in requests:
            self.committed(request["operationId"])
        self.app.idle(session)
        users = [
            event for event in self.app.events(session) if event.get("type") == "user"
        ]
        self.assertEqual(
            [event["operationId"] for event in users],
            [request["operationId"] for request in requests],
        )
        self.assertEqual(
            [event["text"] for event in users],
            [request["content"] for request in requests],
        )
        with self.assertRaises(urllib.error.HTTPError) as replay:
            self.post(path, rejected)
        self.assertEqual(replay.exception.code, 409)
        self.assertEqual(json.load(replay.exception), rejection)
