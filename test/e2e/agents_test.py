"""Agent families: spawn, forwarding, addressing, snapshots, and routing."""

import http.client
import json
import socket
import sqlite3
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import urllib.parse
from pathlib import Path

from harness import Albedo, Provider, exclusive, operation_id, python, text
from stream_pressure_test import StreamProbe


def user_message(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["messages"])
            if item.get("role") == "user"
        ),
        "",
    )


def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("agent event never arrived")


class AgentsTests(unittest.TestCase):
    def setUp(self):
        def answer(request):
            user = user_message(request)
            line = user.splitlines()[-2 if "</mail>" in user else -1]
            return text("answered: " + line)

        self.provider = Provider(answer)
        self.alpha = f"alpha-{self.provider.route}"
        self.beta = f"beta-{self.provider.route}"
        providers = {
            profile: {
                "extension": "openai",
                "baseUrl": self.provider.url + f"/{name}/v1",
                "apiKey": "key",
                "model": f"fixture-{name}-{self.provider.route}",
                "protocol": "chat_completions",
            }
            for profile, name in ((self.alpha, "alpha"), (self.beta, "beta"))
        }

        # The cached catalog lists a model for the fixture endpoint that no profile names.
        # models.json is daemon-wide, so only the exclusive catalog test writes it.
        def prepare(app):
            if (
                self._testMethodName
                == "test_captured_subtree_deletion_blocks_new_child_admission"
            ):
                app.env["ALBEDO_INSPECT"] = "1"
                return
            (app.home / "models.json").write_text(
                json.dumps(
                    {
                        "fixture-gateway": {
                            "api": "http://127.0.0.1/v1",
                            "env": [],
                            "models": {"fixture-listed": {"id": "fixture-listed"}},
                        }
                    }
                )
            )

        catalog = (
            self._testMethodName
            == "test_generic_profile_lists_its_endpoints_catalog_models"
        )
        self.app = Albedo(
            self.provider,
            providers=providers,
            prepare=prepare
            if catalog
            or self._testMethodName
            == "test_captured_subtree_deletion_blocks_new_child_admission"
            else None,
        )
        self.app.__enter__()
        self.addCleanup(self.provider.close)
        self.addCleanup(self.app.__exit__, None, None, None)

    def api(self, path, body=None, **options):
        with self.app.api(path, body, **options) as response:
            return json.load(response)

    def snapshot(self, session):
        return self.api(f"/sessions/{session}?tail=0")

    def change(self, session, patch):
        with self.app.api(f"/sessions/{session}?view=configuration") as response:
            json.load(response)
            revision = response.headers["ETag"]
        return self.api(
            f"/sessions/{session}?view=configuration",
            patch,
            method="PATCH",
            headers={"If-Match": revision},
        )["session"]

    def move(self, session, workspace):
        snapshot = self.snapshot(session)
        return self.change(
            session,
            {
                "workspace": str(workspace),
                "family_revision": snapshot["family_revision"],
            },
        )

    def family(self, session):
        root = self.snapshot(session)["root_id"]
        return self.api(f"/sessions?scope=all&family_id={root}")["items"]

    def asked(self, fragment):
        return [
            content
            for record in self.provider.requests
            for item in record["request"].get("messages", [])
            if item.get("role") == "user"
            for content in [item.get("content", "")]
            if isinstance(content, str) and fragment in content
        ]

    def spawn(self, parent, name="coder", task="map every wake path", model=None):
        session = operation_id()
        body = {
            "kind": "child",
            "parent_id": parent,
            "address": name,
            "name": name,
            "initial_input_id": operation_id(),
            "task": task,
        }
        if model is not None:
            body["model"] = model
        return self.api(
            f"/sessions/{session}", body, method="PUT", headers={"If-None-Match": "*"}
        )

    def send_mail(self, sender, target, body, *, rejected=False):
        marker = "dispatch fixture mail " + operation_id()
        answer = self.provider.script

        def dispatch(request):
            if (
                request["messages"][-1].get("role") == "user"
                and user_message(request) == marker
            ):
                return python(
                    "import json\n"
                    f"receipt = await mail.submit({target!r}, {body!r})\n"
                    "print(json.dumps(receipt))"
                )
            return answer(request)

        self.provider.script = dispatch
        try:
            self.send(sender, marker)
            self.app.idle(sender)
        finally:
            self.provider.script = answer
        [result] = [
            entry
            for entry in self.app.history(sender)["items"]
            if entry["kind"] == "tool_result"
        ][-1:]
        execution = next(
            json.loads(part["value"])
            for part in result["content"]
            if part["kind"] == "json" and part["field"] == "result"
        )
        self.assertEqual(execution["status"], "error" if rejected else "ok", execution)
        return execution if rejected else json.loads(execution["output"])

    def send(self, session, message):
        return self.api(
            f"/sessions/{session}/inputs/{operation_id()}",
            {"kind": "message", "text": message},
            method="PUT",
        )

    def listen(self):
        heard = []
        ready, stopped = threading.Event(), threading.Event()
        address = urllib.parse.urlsplit(self.app.base)
        connection = http.client.HTTPConnection(
            address.hostname, address.port, timeout=30
        )

        def consume():
            try:
                connection.request(
                    "GET",
                    "/sessions?scope=all",
                    headers={
                        "Authorization": "Bearer " + self.app.connection["token"],
                        "Accept": "text/event-stream",
                    },
                )
                with connection.getresponse() as response:
                    for raw in response:
                        if raw.startswith(b"data: "):
                            heard.extend(json.loads(raw[6:])["events"])
                            ready.set()
            except (OSError, ValueError):
                if not stopped.is_set():
                    raise

        thread = threading.Thread(target=consume, daemon=True)
        thread.start()
        self.assertTrue(ready.wait(timeout=5), "collection stream did not send ready")

        def close():
            stopped.set()
            if connection.sock is not None:
                connection.sock.shutdown(socket.SHUT_RDWR)
            thread.join(timeout=2)
            connection.close()
            self.assertFalse(thread.is_alive(), "collection reader did not stop")

        self.addCleanup(close)
        return heard

    def test_spawn_task_and_unreviewed_forward(self):
        parent = self.app.session()
        child = self.spawn(parent)
        self.assertEqual(
            (child["parent_id"], child["address"], child["depth"], child["closed"]),
            (parent, "coder", 1, False),
        )
        self.assertEqual(child["name"], "coder")
        self.assertNotIn(
            child["id"], [item["id"] for item in self.api("/sessions")["items"]]
        )
        self.app.idle(child["id"])
        task = self.asked("map every wake path")[0]
        self.assertIn('kind="task"', task)
        self.assertIn(f'session="{parent}"', task)
        self.assertIn("map every wake path", task)
        forwarded = wait_for(lambda: self.asked('kind="unreviewed"'))[0]
        self.assertIn('from="coder"', forwarded)
        self.assertIn("answered: map every wake path", forwarded)
        self.app.idle(parent)
        self.app.idle(child["id"])
        self.assertEqual(
            [
                item["address"]
                for item in self.api(f"/sessions?scope=all&parent_id={parent}")["items"]
            ],
            ["coder"],
        )

    @exclusive
    def test_mail_attribution_and_agent_card_survive_reconnect_and_restart(self):
        parent = self.app.session()
        self.change(parent, {"name": "lead desk"})
        child = self.spawn(parent, task="map wake paths")["id"]
        self.app.idle(child)
        self.app.idle(parent)
        task = next(
            entry
            for entry in self.app.history(child)["items"]
            if (entry.get("mail") or {}).get("kind") == "task"
        )
        self.assertEqual(task["turn_type"], "agent")
        self.assertEqual(task["mail"]["sender_label"], "lead desk")
        self.assertEqual(task["mail"]["sender_session_id"], parent)
        self.assertEqual(task["input_id"], task["mail"]["mail_id"])
        self.assertEqual(task["content"][0]["text"], "map wake paths")
        # Retrying creation must not admit the initial task twice.
        with self.assertRaises(urllib.error.HTTPError) as repeated:
            self.api(
                f"/sessions/{child}",
                {
                    "kind": "child",
                    "parent_id": parent,
                    "address": "coder",
                    "name": "coder",
                    "initial_input_id": task["input_id"],
                    "task": "map wake paths",
                },
                method="PUT",
                headers={"If-None-Match": "*"},
            )
        self.assertEqual(repeated.exception.code, 412)
        self.assertEqual(
            sum(
                entry["id"] == task["id"] for entry in self.app.history(child)["items"]
            ),
            1,
        )
        self.assertEqual(
            self.snapshot(child)["activity"]["current_request"]["text"],
            "map wake paths",
        )
        before = self.app.stream_page(child)
        answer = self.provider.script
        marker = "report bounded progress"

        def progress(request):
            if (
                request["messages"][-1].get("role") == "user"
                and user_message(request) == marker
            ):
                return python('await agents.progress("tracing delivery")')
            return answer(request)

        self.provider.script = progress
        self.send(child, marker)
        self.app.idle(child)
        self.app.idle(parent)
        self.provider.script = answer
        self.assertEqual(
            self.snapshot(child)["activity"]["latest_progress"], "tracing delivery"
        )
        # A new subscriber sees progress in its authoritative reset snapshot.
        reset = self.app.stream_page(child)
        self.assertEqual(
            reset["snapshot"]["activity"]["latest_progress"], "tracing delivery"
        )
        receipt = self.send_mail(parent, child, "also cover replay")
        self.app.idle(child)
        self.app.idle(parent)
        activity = self.snapshot(child)["activity"]
        self.assertEqual(
            activity["current_request"],
            {"input_id": receipt["id"], "text": "also cover replay"},
        )
        self.assertIsNone(activity["latest_progress"])
        history = self.app.history(child)["items"]
        followup = next(
            entry for entry in history if entry["input_id"] == receipt["id"]
        )
        live = self.app.stream_page(child, before)
        self.assertEqual(
            [
                event["data"]["entry"]
                for event in live["events"]
                if event["type"] == "message"
                and event["data"]["entry"]["id"] == followup["id"]
            ],
            [followup],
        )
        # Peer messages remain visible but cannot replace the parent's request.
        peer = self.app.session()
        self.send_mail(peer, child, "peer observation")
        self.app.idle(child)
        self.app.idle(parent)
        self.assertEqual(
            self.snapshot(child)["activity"]["current_request"],
            activity["current_request"],
        )
        forwarded = next(
            entry
            for entry in self.app.history(parent)["items"]
            if (entry.get("mail") or {}).get("kind") == "unreviewed"
        )
        self.assertEqual(forwarded["mail"]["sender_label"], "coder")
        self.app.restart()
        recovered = self.snapshot(child)["activity"]
        self.assertEqual(recovered["current_request"], activity["current_request"])
        self.assertIsNone(recovered["latest_progress"])
        replayed = self.app.stream_page(child)["snapshot"]["history"]["items"]
        self.assertEqual(
            next(entry for entry in replayed if entry["id"] == followup["id"]), followup
        )

    def test_tree_snapshot_and_event_stream(self):
        parent = self.app.session()
        heard = self.listen()
        child = self.spawn(parent)["id"]
        wait_for(lambda: self.asked('kind="unreviewed"'))
        for asker in (parent, child):
            nodes = {item["id"]: item for item in self.family(asker)}
            self.assertEqual(set(nodes), {parent, child})
            self.assertEqual(
                (nodes[parent]["parent_id"], nodes[parent]["depth"]), (None, 0)
            )
            self.assertEqual(
                (
                    nodes[child]["parent_id"],
                    nodes[child]["depth"],
                    nodes[child]["address"],
                ),
                (parent, 1, "coder"),
            )
        wait_for(
            lambda: any(
                event["type"] == "invalidate" and child in event["data"]["session_ids"]
                for event in list(heard)
            )
        )
        wait_for(
            lambda: any(
                event["type"] == "activity" and event["data"]["session_id"] == child
                for event in list(heard)
            )
        )
        wait_for(
            lambda: any(
                event["type"] == "mail"
                and event["data"]["receiver_session_id"] == parent
                for event in list(heard)
            )
        )

    def test_rename_keeps_family_address_and_reports_stream_event(self):
        parent = self.app.session()
        child = self.spawn(parent)["id"]
        self.app.idle(child)
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        heard = self.listen()
        self.assertEqual(
            self.change(child, {"name": "  wake path\naudit "})["name"],
            "wake path audit",
        )
        self.assertEqual(
            self.change(parent, {"name": "orchestration"})["name"], "orchestration"
        )
        nodes = {item["id"]: item for item in self.family(parent)}
        self.assertEqual(
            (nodes[parent]["name"], nodes[parent]["address"]), ("orchestration", None)
        )
        self.assertEqual(
            (nodes[child]["name"], nodes[child]["address"]),
            ("wake path audit", "coder"),
        )
        wait_for(
            lambda: any(
                event["type"] == "invalidate" and child in event["data"]["session_ids"]
                for event in list(heard)
            )
        )
        self.assertEqual(self.snapshot(child)["name"], "wake path audit")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.send("no-such-session", "cannot deliver")
        self.assertEqual(caught.exception.code, 404)
        receipt = self.send_mail(parent, "coder", "also cover schedules")
        self.assertEqual((receipt["to"], receipt["name"]), (child, "coder"))
        wait_for(lambda: self.asked("also cover schedules"))
        wait_for(
            lambda: any(
                "also cover schedules" in message
                for message in self.asked('kind="unreviewed"')
            )
        )
        self.app.idle(parent)

    def test_reply_and_external_id_mail(self):
        parent, radio = self.app.session(), self.app.session()
        child = self.spawn(parent)["id"]
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        self.app.idle(child)
        receipt = self.send_mail(child, "parent", "schedules covered")
        self.assertEqual(receipt["to"], parent)
        wait_for(lambda: self.asked("schedules covered"))
        self.app.idle(parent)
        failed = self.send_mail(child, "radio", "by unrelated name", rejected=True)
        self.assertIn("radio", failed["output"])
        self.assertFalse(self.asked("by unrelated name"))
        receipt = self.send_mail(child, radio, "deploy when green")
        self.assertEqual(receipt["to"], radio)
        wait_for(lambda: self.asked("deploy when green"))
        self.app.idle(radio)
        for recipient, body in (
            (parent, "schedules covered"),
            (radio, "deploy when green"),
        ):
            delivered = [
                entry
                for entry in self.app.history(recipient)["items"]
                if entry["kind"] == "user"
                and any(
                    part["kind"] == "text" and body in part["text"]
                    for part in entry["content"]
                )
            ]
            self.assertEqual(len(delivered), 1)

    def test_tree_deletion_and_renamed_workspace(self):
        parent = self.app.session()
        child = self.spawn(parent)["id"]
        self.app.idle(child)
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            configuration = json.load(response)
            revision = response.headers["ETag"]
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.api(
                f"/sessions/{parent}?view=configuration",
                method="DELETE",
                headers={"If-Match": revision},
            )
        self.assertEqual(caught.exception.code, 409)
        self.assertIn("child", json.load(caught.exception)["detail"])
        grandchild = self.spawn(child, "deep")["id"]
        self.app.idle(grandchild)
        wait_for(lambda: len(self.asked('kind="unreviewed"')) >= 2)
        self.app.idle(child)
        self.app.idle(parent)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.api(
                f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={configuration['family_revision']}",
                method="DELETE",
                headers={"If-Match": revision},
            )
        self.assertEqual(caught.exception.code, 412)
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        answer = self.provider.script

        def held(request):
            if "hold subtree deletion" in user_message(request):
                entered.set()
                release.wait(30)
                return python(
                    "from pathlib import Path\nPath('deleted-run-executed').write_text('wrong')"
                )
            return answer(request)

        self.provider.script = held
        receipt = self.send(child, "hold subtree deletion")
        self.assertTrue(entered.wait(30))
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            configuration = json.load(response)
            revision = response.headers["ETag"]
        outcome = self.api(
            f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={configuration['family_revision']}",
            method="DELETE",
            headers={"If-Match": revision},
        )
        self.assertEqual(outcome["state"], "complete")
        self.assertEqual(outcome["deleted_ids"], [grandchild, child, parent])
        terminal = self.api(f"/sessions/{child}/inputs/{receipt['id']}")
        self.assertEqual(terminal["delivery"], "committed")
        self.assertEqual(terminal["turn"]["state"], "interrupted")
        self.assertIsNotNone(terminal["turn"]["ended_at"])
        release.set()
        self.assertFalse((self.app.workspace / "deleted-run-executed").exists())
        listed = [item["id"] for item in self.api("/sessions?scope=all")["items"]]
        self.assertNotIn(parent, listed)
        self.assertNotIn(child, listed)
        radio = self.app.session()
        self.change(radio, {"name": "radio desk"})
        moved = self.app.root / "moved"
        moved.mkdir()
        self.assertEqual(self.move(radio, moved)["name"], "radio desk")
        self.assertEqual(self.snapshot(radio)["name"], "radio desk")

    @exclusive
    def test_captured_subtree_deletion_blocks_new_child_admission(self):
        parent = self.app.session()
        child = self.spawn(parent, "captured")["id"]
        self.app.idle(child)
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            configuration = json.load(response)
            revision = response.headers["ETag"]
        probe = StreamProbe(self.app)
        self.assertEqual(
            probe.call("suspend_session_json", f"[<<{json.dumps(child)}>>]"),
            {"suspended": True},
        )
        outcomes, failures = [], []

        def delete():
            try:
                outcomes.append(
                    self.api(
                        f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={configuration['family_revision']}",
                        method="DELETE",
                        headers={"If-Match": revision},
                    )
                )
            except Exception as error:
                failures.append(error)

        worker = threading.Thread(target=delete)
        worker.start()
        try:

            def captured():
                with sqlite3.connect(self.app.home / "albedo.sqlite") as db:
                    rows = db.execute(
                        "SELECT id,deletion_id FROM sessions WHERE id IN (?,?)",
                        (parent, child),
                    ).fetchall()
                return len(rows) == 2 and all(row[1] for row in rows)

            wait_for(captured, timeout=15)
            self.assertTrue(worker.is_alive())
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.spawn(parent, "too-late", "must not execute")
            self.assertEqual(caught.exception.code, 409)
            with sqlite3.connect(self.app.home / "albedo.sqlite") as db:
                admitted = {
                    row[0]
                    for row in db.execute(
                        "SELECT id FROM sessions WHERE id=? UNION ALL "
                        "SELECT session FROM session_family WHERE parent=?",
                        (parent, parent),
                    )
                }
            self.assertEqual(admitted, {parent, child})
        finally:
            self.assertEqual(
                probe.call("resume_session_json", f"[<<{json.dumps(child)}>>]"),
                {"resumed": True},
            )
            worker.join(35)
        self.assertFalse(
            worker.is_alive(), "deletion did not finish after owner resumed"
        )
        self.assertEqual(failures, [])
        self.assertEqual(len(outcomes), 1)
        self.assertEqual(outcomes[0]["state"], "complete")
        self.assertEqual(outcomes[0]["deleted_ids"], [child, parent])
        self.assertFalse(self.asked("must not execute"))

    @exclusive
    def test_subtree_deletion_reports_the_rows_a_failed_commit_leaves(self):
        parent = self.app.session()
        failed = self.spawn(parent, "failed")["id"]
        removed = self.spawn(parent, "removed")["id"]
        for session in (failed, removed):
            self.app.idle(session)
        wait_for(lambda: self.asked('from="failed"') and self.asked('from="removed"'))
        self.app.idle(parent)
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            configuration = json.load(response)
            revision = response.headers["ETag"]
        with sqlite3.connect(self.app.home / "albedo.sqlite") as db:
            db.execute(
                "CREATE TRIGGER fail_observed_deletion BEFORE DELETE ON sessions "
                f"WHEN OLD.id='{failed}' BEGIN SELECT RAISE(ABORT,'injected deletion failure'); END"
            )
        self.addCleanup(self._remove_deletion_failure)
        outcome = self.api(
            f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={configuration['family_revision']}",
            method="DELETE",
            headers={"If-Match": revision},
        )
        self.assertEqual(outcome["state"], "partial")
        self.assertEqual(outcome["deleted_count"], 1)
        self.assertEqual(outcome["remaining_count"], 2)
        self.assertEqual(outcome["deleted_ids"], [removed])
        remaining = {row["id"]: row["reason"] for row in outcome["remaining"]}
        self.assertEqual(set(remaining), {parent, failed})
        self.assertTrue(all(remaining.values()))
        self.assertIn("captured child", remaining[parent]["detail"])
        self._remove_deletion_failure()
        # Reading authoritative state never resumes a partially failed deletion.
        for _ in range(2):
            self.assertEqual(
                {row["id"] for row in self.family(parent)}, {parent, failed}
            )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.api(
                f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={configuration['family_revision']}",
                method="DELETE",
                headers={"If-Match": revision},
            )
        self.assertEqual(caught.exception.code, 412)
        self.assertEqual({row["id"] for row in self.family(parent)}, {parent, failed})

    def _remove_deletion_failure(self):
        with sqlite3.connect(self.app.home / "albedo.sqlite") as db:
            db.execute("DROP TRIGGER IF EXISTS fail_observed_deletion")

    def test_children_follow_a_workspace_move(self):
        release = threading.Event()
        self.addCleanup(release.set)
        answer = self.provider.script

        def held(request):
            user = user_message(request)
            if "hold this turn" in user or "probe moved child" in user:
                if request["messages"][-1].get("role") == "tool":
                    return text("workspace probe finished")
                if "hold this turn" in user:
                    release.wait(30)
                marker = (
                    "old-child-cwd" if "hold this turn" in user else "new-child-cwd"
                )
                return python(
                    "import os\nfrom pathlib import Path\n"
                    f"Path({marker!r}).write_text(os.getcwd())"
                )
            return answer(request)

        self.provider.script = held
        parent = self.app.session()
        still = self.spawn(parent, "still")["id"]
        away = self.spawn(parent, "away")["id"]

        def heard():
            return {
                entry["mail"]["sender_session_id"]
                for entry in self.app.history(parent)["items"]
                if entry.get("mail")
            }

        wait_for(lambda: {still, away} <= heard())
        for session in (still, away, parent):
            self.app.idle(session)
        elsewhere = Path(tempfile.mkdtemp(prefix="elsewhere-", dir=self.app.root))
        self.move(away, elsewhere)
        busy = self.spawn(parent, "busy", "hold this turn")["id"]
        wait_for(lambda: self.asked("hold this turn"))
        moved = Path(tempfile.mkdtemp(prefix="moved-", dir=self.app.root))
        self.assertEqual(self.move(parent, moved)["workspace"], str(moved))

        def workspaces():
            return {item["id"]: item["workspace"] for item in self.family(parent)}

        self.assertEqual(
            workspaces(),
            {
                parent: str(moved),
                still: str(moved),
                away: str(elsewhere),
                busy: str(self.app.workspace),
            },
        )
        latest = Path(tempfile.mkdtemp(prefix="latest-", dir=self.app.root))
        self.move(parent, latest)
        before_move_applied = self.app.stream_page(busy)
        release.set()
        self.app.idle(busy)
        self.assertEqual(workspaces()[busy], str(latest))
        self.assertEqual(
            (self.app.workspace / "old-child-cwd").read_text(), str(self.app.workspace)
        )
        self.assertFalse((moved / "old-child-cwd").exists())
        self.send(busy, "probe moved child")
        self.app.idle(busy)
        self.assertEqual((latest / "new-child-cwd").read_text(), str(latest))
        self.assertFalse((moved / "new-child-cwd").exists())
        events = self.app.stream_page(busy, before_move_applied)["events"]
        notes = [
            event["data"]["text"]
            for event in events
            if event["type"] == "note" and event["data"]["origin"] == "workspace"
        ]
        self.assertTrue(
            any(
                "python variables were cleared" in note
                and "transcript is intact" in note
                for note in notes
            ),
            events,
        )

    @exclusive
    def test_failed_deferred_workspace_application_survives_restart(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        answer = self.provider.script

        def held(request):
            user = user_message(request)
            if "deferred workspace hold" in user:
                entered.set()
                release.wait(30)
                return text("old turn completed")
            if "restored workspace probe" in user:
                if request["messages"][-1].get("role") == "tool":
                    return text("restored workspace completed")
                return python(
                    "import os\nfrom pathlib import Path\n"
                    "Path('restored-child-cwd').write_text(os.getcwd())"
                )
            return answer(request)

        self.provider.script = held
        parent = self.app.session()
        child = self.spawn(parent, "deferred", "deferred workspace hold")["id"]
        self.assertTrue(entered.wait(30), "child never reached provider gate")
        destination = Path(tempfile.mkdtemp(prefix="deferred-", dir=self.app.root))
        self.move(parent, destination)
        destination.rmdir()
        release.set()
        self.app.idle(child)

        def assert_pending():
            snapshot = self.snapshot(child)
            self.assertEqual(snapshot["workspace"], str(self.app.workspace))
            change = snapshot["workspace_change"]
            self.assertEqual(change["active"], str(self.app.workspace))
            self.assertEqual(change["desired"], str(destination))
            return change["revision"]

        revision = assert_pending()
        self.app.restart(crash=True)
        self.assertEqual(assert_pending(), revision)
        destination.mkdir()
        self.send(child, "restored workspace probe")
        self.app.idle(child)
        self.assertEqual(
            (destination / "restored-child-cwd").read_text(), str(destination)
        )
        snapshot = self.snapshot(child)
        self.assertEqual(snapshot["workspace"], str(destination))
        self.assertIsNone(snapshot["workspace_change"])
        self.assertFalse((self.app.workspace / "restored-child-cwd").exists())

    def test_qualified_and_inferred_cross_provider_models(self):
        parent = self.app.session()
        self.change(parent, {"name": "radio desk"})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.spawn(
                parent, "missing", "should not run", f"{self.beta}/no-such-model"
            )
        self.assertEqual(caught.exception.code, 409)
        for name, model in (
            ("explicit", f"{self.beta}/fixture-beta-{self.provider.route}"),
            ("inferred", f"fixture-beta-{self.provider.route}"),
        ):
            made = self.spawn(parent, name, "cross-provider task", model)
            self.assertEqual(made["provider_profile"], self.beta)
            self.assertEqual(made["model"], f"fixture-beta-{self.provider.route}")
            self.assertEqual(made["parent_id"], parent)
            self.app.idle(made["id"])
        tasks = wait_for(
            lambda: (
                self.asked('kind="task">\ncross-provider')
                if len(self.asked('kind="task">\ncross-provider')) == 2
                else None
            )
        )
        self.assertTrue(all('from="radio desk"' in task for task in tasks))
        self.assertGreaterEqual(
            sum("/beta/" in record["path"] for record in self.provider.requests), 2
        )

    # exclusive: writes the daemon-wide models.json catalog
    @exclusive
    def test_generic_profile_lists_its_endpoints_catalog_models(self):
        parent = self.app.session()
        made = self.spawn(
            parent, "listed", "catalog task", f"{self.beta}/fixture-listed"
        )
        self.assertEqual(
            (made["provider_profile"], made["model"]), (self.beta, "fixture-listed")
        )
        self.app.idle(made["id"])
