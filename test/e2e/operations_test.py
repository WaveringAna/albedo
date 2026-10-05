"""Identified inputs retain their admission and deliver once through failure and restart."""

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

from harness import Albedo, Provider, exclusive, operation_id, python, text
from image_limits_test import png


class InputScenario(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _: text("done"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def put_input(self, session, input_id, intent):
        with self.app.api(
            f"/sessions/{session}/inputs/{input_id}", intent, method="PUT"
        ) as response:
            return json.load(response)

    def receipt(self, session, input_id):
        with self.app.api(f"/sessions/{session}/inputs/{input_id}") as response:
            return json.load(response)

    def committed(self, session, input_id):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            receipt = self.receipt(session, input_id)
            if receipt["delivery"] == "committed":
                return receipt
            time.sleep(0.03)
        self.fail(f"input remained pending: {receipt}")

    def duplicates(self, session, input_id, intent):
        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(
                executor.map(
                    lambda _: self.put_input(session, input_id, intent), range(6)
                )
            )
        self.assertTrue(
            all(
                result["id"] == input_id and result["admission"] == "accepted"
                for result in results
            )
        )
        self.assertEqual(len({result["acceptance_order"] for result in results}), 1)
        return results[0]

    def conflict(self, session, input_id, intent):
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.put_input(session, input_id, intent)
        self.assertEqual(failure.exception.code, 409)
        self.assertEqual(json.load(failure.exception)["code"], "input_conflict")

    def users(self, session):
        return [
            entry
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "user"
        ]

    def skill_intent(self, session, arguments):
        with self.app.api(f"/sessions/{session}/catalog?kind=skills") as response:
            discovery = json.load(response)["discovery"]
        candidate = next(
            row for row in discovery["candidates"] if row["title"] == "retry-skill"
        )
        return {
            "kind": "skill",
            "candidate_id": candidate["id"],
            "catalog_revision": discovery["revision"],
            "arguments": arguments,
        }

    def write_skill(self):
        skill = self.app.workspace / ".agents/skills/retry-skill/SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: retry-skill\ndescription: test activation\n---\nOriginal saved instructions.\n"
        )
        return skill

    def assert_user_order(self, session, inputs):
        users = self.users(session)
        self.assertEqual(
            [entry["input_id"] for entry in users], [input_id for input_id, _ in inputs]
        )
        self.assertEqual(
            [
                part["text"]
                for entry in users
                for part in entry["content"]
                if part["kind"] == "text"
            ],
            [intent["text"] for _, intent in inputs],
        )


class OperationsTests(InputScenario):
    def test_targeted_cancel_preserves_shared_turn_and_cannot_interrupt_a_later_turn(
        self,
    ):
        first_entered, second_entered, later_entered = [
            threading.Event() for _ in range(3)
        ]
        first_release, second_release, later_release = [
            threading.Event() for _ in range(3)
        ]
        for gate in (first_release, second_release, later_release):
            self.addCleanup(gate.set)
        calls = 0

        def reply(_request):
            nonlocal calls
            calls += 1
            entered, release = [
                (first_entered, first_release),
                (second_entered, second_release),
                (later_entered, later_release),
            ][calls - 1]
            entered.set()
            if not release.wait(20):
                raise AssertionError(
                    "targeted cancellation scenario did not release provider"
                )
            return python("1") if calls == 1 else text("completed")

        self.provider.script = reply
        session = self.app.session()
        identities = [operation_id() for _ in range(3)]
        self.put_input(
            session, identities[0], {"kind": "message", "text": "start shared turn"}
        )
        self.assertTrue(first_entered.wait(10))
        for index, identity in enumerate(identities[1:]):
            self.put_input(
                session,
                identity,
                {"kind": "message", "text": f"join shared turn {index}"},
            )
        first_release.set()
        self.assertTrue(second_entered.wait(15))
        receipts = [self.committed(session, identity) for identity in identities]
        turn_ids = {receipt["turn"]["id"] for receipt in receipts}
        self.assertEqual(len(turn_ids), 1)
        with self.app.api(
            f"/sessions/{session}/inputs/{identities[1]}/cancel", {}
        ) as response:
            cancellation = json.load(response)
        self.assertEqual(cancellation["result"], "shared_running")
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            self.assertFalse(json.load(response)["status"]["interrupt_requested"])
        second_release.set()
        self.app.idle(session)
        self.assertTrue(
            all(
                self.receipt(session, identity)["turn"]["state"] == "completed"
                for identity in identities
            )
        )
        later = operation_id()
        self.put_input(
            session, later, {"kind": "message", "text": "a later independent turn"}
        )
        self.assertTrue(later_entered.wait(10))
        with self.app.api(
            f"/sessions/{session}/inputs/{identities[0]}/cancel", {}
        ) as response:
            self.assertEqual(json.load(response)["result"], "not_pending")
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            snapshot = json.load(response)
        self.assertFalse(snapshot["status"]["interrupt_requested"])
        self.assertNotIn(snapshot["status"]["run_id"], turn_ids)
        later_release.set()
        self.app.idle(session)
        self.assertEqual(self.receipt(session, later)["turn"]["state"], "completed")

    def test_concurrent_creation_has_one_resource_and_immutable_provenance(self):
        session_id = operation_id()
        resource = f"/sessions/{session_id}"
        intent = {
            "kind": "new",
            "workspace": str(self.app.workspace),
            "provider_profile": self.app.profile,
        }

        def create(_):
            try:
                with self.app.api(
                    resource, intent, method="PUT", headers={"If-None-Match": "*"}
                ) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as failure:
                self.assertEqual(failure.code, 412)
                return failure.code, None

        with ThreadPoolExecutor(max_workers=6) as executor:
            results = list(executor.map(create, range(6)))
        self.assertEqual([status for status, _ in results].count(201), 1)
        with self.app.api(resource) as response:
            created = json.load(response)
        self.assertEqual(
            created["creation"]["submitted"]["workspace"], intent["workspace"]
        )
        self.assertEqual(
            created["creation"]["resolved"],
            {
                key: created[key]
                for key in ("workspace", "provider_profile", "model", "effort")
            },
        )
        configuration = created["configuration_resource"]
        with self.app.api(
            configuration["url"],
            {"name": "edited after creation"},
            method="PATCH",
            headers={"If-Match": configuration["etag"]},
        ) as response:
            response.read()
        with self.app.api(resource) as response:
            edited = json.load(response)
        self.assertEqual(edited["creation"], created["creation"])
        self.assertEqual(edited["name"], "edited after creation")
        with self.app.api("/sessions?scope=all") as response:
            matches = [
                row for row in json.load(response)["items"] if row["id"] == session_id
            ]
        self.assertEqual(len(matches), 1)

    def test_submission_identity_and_durable_echo(self):
        session = self.app.session()
        first = operation_id()
        intent = {"kind": "message", "text": "same message", "client_id": "first"}
        self.duplicates(session, first, intent)
        duplicate = self.put_input(session, first, {**intent, "client_id": "retry"})
        self.assertEqual(duplicate["client_id"], "first")
        self.committed(session, first)
        self.app.idle(session)
        self.conflict(session, first, {**intent, "text": "changed message"})
        self.conflict(session, first, {"kind": "continue"})
        second = operation_id()
        self.put_input(session, second, {**intent, "client_id": "second"})
        self.committed(session, second)
        self.app.idle(session)
        self.assert_user_order(session, [(first, intent), (second, intent)])

    def test_image_duplicates_and_changed_image_conflict(self):
        session = self.app.session()
        input_id = operation_id()
        intent = {
            "kind": "message",
            "text": "inspect image",
            "images": [
                {
                    "mime_type": "image/png",
                    "data": base64.b64encode(png(2, 2)).decode(),
                }
            ],
        }
        self.duplicates(session, input_id, intent)
        self.committed(session, input_id)
        self.app.idle(session)
        self.conflict(
            session,
            input_id,
            {
                **intent,
                "images": [
                    {
                        **intent["images"][0],
                        "data": base64.b64encode(png(3, 2)).decode(),
                    }
                ],
            },
        )
        users = self.users(session)
        self.assertEqual([entry["input_id"] for entry in users], [input_id])
        image = next(
            part["image"] for part in users[0]["content"] if part["kind"] == "image"
        )
        self.assertEqual(image["width"], 2)

    def test_continue_is_one_admission_without_an_extra_user_row(self):
        session = self.app.session()
        self.app.prompt(session, "start").close()
        self.app.idle(session)
        input_id = operation_id()
        self.duplicates(session, input_id, {"kind": "continue"})
        self.committed(session, input_id)
        self.app.idle(session)
        self.assertEqual(len(self.users(session)), 1)
        self.assertEqual(len(self.provider.requests), 2)
        self.assertIsNotNone(self.receipt(session, input_id)["transcript_position"])

    def test_skill_admission_uses_resolved_content_once(self):
        skill = self.write_skill()
        session = self.app.session()
        input_id = operation_id()
        intent = self.skill_intent(session, "do this")
        accepted = self.duplicates(session, input_id, intent)
        self.committed(session, input_id)
        self.app.idle(session)
        skill.unlink()
        duplicate = self.put_input(session, input_id, intent)
        self.assertEqual(duplicate["acceptance_order"], accepted["acceptance_order"])
        self.conflict(session, input_id, {**intent, "arguments": "other"})
        self.assertIn(
            "Original saved instructions.", json.dumps(self.provider.requests)
        )
        self.assertEqual(
            [entry["input_id"] for entry in self.users(session)], [input_id]
        )


@exclusive
class WaitingOperationsTests(InputScenario):
    def setUp(self):
        self.gate = threading.Event()
        self.started = threading.Event()
        self.first = True

        def reply(_):
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
        inputs = [
            (operation_id(), {"kind": "message", "text": f"waiting {index}"})
            for index in range(32)
        ]
        results = [
            self.put_input(session, input_id, intent) for input_id, intent in inputs
        ]
        self.assertTrue(all(result["delivery"] == "pending" for result in results))
        self.assertEqual(
            self.put_input(session, *inputs[0])["acceptance_order"],
            results[0]["acceptance_order"],
        )
        with self.assertRaises(urllib.error.HTTPError) as full:
            self.put_input(
                session, operation_id(), {"kind": "message", "text": "queue overflow"}
            )
        self.assertEqual(full.exception.code, 429)
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            snapshot = json.load(response)
        self.app.api(
            f"/sessions/{session}/interrupt",
            {
                "run_id": snapshot["status"]["run_id"],
                "through_input_order": snapshot["input_order"],
            },
        ).close()
        self.gate.set()
        self.app.idle(session)
        self.app.restart(crash=True)
        for (input_id, intent), accepted in zip(inputs, results):
            self.assertEqual(self.receipt(session, input_id)["delivery"], "cancelled")
            self.assertEqual(
                self.put_input(session, input_id, intent)["acceptance_order"],
                accepted["acceptance_order"],
            )

    def test_crash_recovers_order_images_and_resolved_skill_content(self):
        skill = self.write_skill()
        session = self.app.session()
        with self.app.prompt(session, "hold active generation") as response:
            active_input = json.load(response)["id"]
        self.assertTrue(self.started.wait(10))
        inputs = [
            (operation_id(), {"kind": "message", "text": "first waiting"}),
            (
                operation_id(),
                {
                    "kind": "message",
                    "text": "second image",
                    "images": [
                        {
                            "mime_type": "image/png",
                            "data": base64.b64encode(png(2, 2)).decode(),
                        }
                    ],
                },
            ),
            (operation_id(), self.skill_intent(session, "saved arguments")),
        ]
        accepted = [
            self.put_input(session, input_id, intent) for input_id, intent in inputs
        ]
        self.assertTrue(
            all(
                self.receipt(session, input_id)["delivery"] == "pending"
                for input_id, _ in inputs
            )
        )
        skill.unlink()
        self.app.restart(crash=True)
        self.assertEqual(
            self.receipt(session, active_input)["turn"]["state"], "abandoned"
        )
        self.gate.set()
        for input_id, _ in inputs:
            self.committed(session, input_id)
        self.app.idle(session)
        self.app.restart(crash=True)
        for (input_id, intent), result in zip(inputs, accepted):
            self.assertEqual(
                self.put_input(session, input_id, intent)["acceptance_order"],
                result["acceptance_order"],
            )
        users = [
            entry
            for entry in self.users(session)
            if entry["input_id"] in {input_id for input_id, _ in inputs}
        ]
        self.assertEqual(
            [entry["input_id"] for entry in users], [input_id for input_id, _ in inputs]
        )
        image = next(
            part["image"] for part in users[1]["content"] if part["kind"] == "image"
        )
        self.assertEqual(image["width"], 2)
        self.assertIn(
            "Original saved instructions.", json.dumps(self.provider.requests)
        )


@exclusive
class BlockedOperationsTests(InputScenario):
    def test_full_blocked_queue_survives_restart_and_replays_rejection(self):
        session = self.app.session()
        inputs = [
            (operation_id(), {"kind": "message", "text": f"blocked {index}"})
            for index in range(32)
        ]
        with sqlite3.connect(self.app.home / "albedo.sqlite") as database:
            database.execute(
                "CREATE TRIGGER hold_inputs BEFORE INSERT ON transcript WHEN NEW.row_class='user' BEGIN SELECT RAISE(ABORT,'fixture'); END"
            )
        accepted = [
            self.put_input(session, input_id, intent) for input_id, intent in inputs
        ]
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if self.receipt(session, inputs[0][0])["blocking_reason"]:
                break
            time.sleep(0.03)
        else:
            self.fail("waiting inputs were never blocked")
        rejected_id = operation_id()
        rejected = {"kind": "message", "text": "blocked overflow"}
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.put_input(session, rejected_id, rejected)
        self.assertEqual(failure.exception.code, 429)
        rejection = json.load(failure.exception)
        self.assertEqual(self.receipt(session, rejected_id)["admission"], "rejected")
        self.app.restart(crash=True)
        self.assertEqual(
            self.put_input(session, *inputs[-1])["acceptance_order"],
            accepted[-1]["acceptance_order"],
        )
        with self.assertRaises(urllib.error.HTTPError) as restored_full:
            self.put_input(session, operation_id(), {"kind": "continue"})
        self.assertEqual(restored_full.exception.code, 429)
        with sqlite3.connect(self.app.home / "albedo.sqlite") as database:
            database.execute("DROP TRIGGER hold_inputs")
        for input_id, _ in inputs:
            self.committed(session, input_id)
        self.app.idle(session)
        self.assert_user_order(session, inputs)
        with self.assertRaises(urllib.error.HTTPError) as replay:
            self.put_input(session, rejected_id, rejected)
        self.assertEqual(replay.exception.code, 429)
        self.assertEqual(json.load(replay.exception), rejection)


# exclusive: changes daemon PATH to gate kernel startup; also tests restart
@exclusive
class PreparingOperationsTests(InputScenario):
    opened: Path
    release: Path

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
                # a detached kernel opens through its bridge's start
                + 'case "$*" in *albedo_kernel.py*|*"albedo_bridge.py start"*)\n'
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
        input_id = operation_id()
        intent = {"kind": "message", "text": "stored while kernel opens"}
        accepted = self.put_input(session, input_id, intent)
        deadline = time.monotonic() + 10
        while not self.opened.exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        self.assertTrue(self.opened.exists())
        self.assertEqual(self.receipt(session, input_id)["delivery"], "pending")
        self.app.restart(crash=True, prepare=lambda _: self.release.touch())
        self.assertEqual(
            self.put_input(session, input_id, intent)["acceptance_order"],
            accepted["acceptance_order"],
        )
        self.committed(session, input_id)
        self.app.idle(session)
        self.assertEqual(
            [entry["input_id"] for entry in self.users(session)], [input_id]
        )

    def test_full_kernel_opening_queue_delivers_once_and_replays_rejection(self):
        session = self.app.session()
        inputs = [
            (operation_id(), {"kind": "message", "text": f"opening {index}"})
            for index in range(32)
        ]
        results = [
            self.put_input(session, input_id, intent) for input_id, intent in inputs
        ]
        deadline = time.monotonic() + 10
        while not self.opened.exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        self.assertTrue(self.opened.exists())
        self.assertEqual(
            self.put_input(session, *inputs[0])["acceptance_order"],
            results[0]["acceptance_order"],
        )
        rejected_id = operation_id()
        intent = {"kind": "continue"}
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.put_input(session, rejected_id, intent)
        self.assertEqual(failure.exception.code, 429)
        rejection = json.load(failure.exception)
        self.assertEqual(self.receipt(session, rejected_id)["admission"], "rejected")
        self.release.touch()
        for input_id, _ in inputs:
            self.committed(session, input_id)
        self.app.idle(session)
        self.assert_user_order(session, inputs)
        with self.assertRaises(urllib.error.HTTPError) as replay:
            self.put_input(session, rejected_id, intent)
        self.assertEqual(replay.exception.code, 429)
        self.assertEqual(json.load(replay.exception), rejection)
