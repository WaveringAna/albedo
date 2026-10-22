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

from harness import Albedo, Provider, exclusive, latest_user, operation_id, python, text
from stream_support import StreamProbe


def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("agent event never arrived")


REMINDER = "You have not answered your parent yet."


class AgentsTests(unittest.TestCase):
    def setUp(self):
        def answer(request):
            # A child reminded to answer its parent repeats what it found.
            users = [
                item["content"]
                for item in request.get("messages", [])
                if item.get("role") == "user" and isinstance(item.get("content"), str)
            ]
            user = next(
                (item for item in reversed(users) if REMINDER not in item),
                latest_user(request),
            )
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
        if self._testMethodName == "test_a_stalled_endpoint_never_stalls_the_daemon":
            # Accepts connections and never answers, like a gateway whose host
            # is up and whose server is wedged.
            stalled = socket.create_server(("127.0.0.1", 0))
            held = []

            def hold():
                while True:
                    try:
                        held.append(stalled.accept()[0])
                    except OSError:
                        return

            threading.Thread(target=hold, daemon=True).start()
            self.addCleanup(lambda: [c.close() for c in held])
            self.addCleanup(stalled.close)
            providers[f"stalled-{self.provider.route}"] = {
                "extension": "openai",
                "baseUrl": f"http://127.0.0.1:{stalled.getsockname()[1]}/v1",
                "apiKey": "key",
                "model": f"fixture-stalled-{self.provider.route}",
                "protocol": "chat_completions",
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
                and latest_user(request) == marker
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

    def execute(self, session, source):
        marker = "execute fixture python " + operation_id()
        answer = self.provider.script

        def dispatch(request):
            if (
                request["messages"][-1].get("role") == "user"
                and latest_user(request) == marker
            ):
                return python(source)
            return answer(request)

        self.provider.script = dispatch
        try:
            self.send(session, marker)
            self.app.idle(session)
        finally:
            self.provider.script = answer
        result = [
            entry
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result"
        ][-1]
        execution = next(
            json.loads(part["value"])
            for part in result["content"]
            if part["kind"] == "json" and part["field"] == "result"
        )
        self.assertEqual(execution["status"], "ok", execution)
        return execution["output"]

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
        resource = self.api(f"/sessions/{child['id']}")
        self.assertEqual(
            resource["creation"]["resolved"],
            {
                key: resource[key]
                for key in ("workspace", "provider_profile", "model", "effort")
            },
        )
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
        # Asked once to answer before it stopped; the forward is the fallback.
        self.assertEqual(len(self.asked(REMINDER)), 1)
        self.app.idle(parent)
        self.app.idle(child["id"])
        self.assertEqual(
            [
                item["address"]
                for item in self.api(f"/sessions?scope=all&parent_id={parent}")["items"]
            ],
            ["coder"],
        )

    # exclusive: saves extensions.json
    @exclusive
    def test_saved_subagent_limits_hold_for_the_next_child(self):
        settings = self.app.home / "extensions.json"
        settings.write_text(
            json.dumps({"subagents": {"maxOpenChildren": 1, "maxDepth": 1}})
        )
        parent = self.app.session()
        first = self.spawn(parent, "first")["id"]
        for under, name in ((parent, "second"), (first, "deeper")):
            with self.subTest(name=name):
                with self.assertRaises(urllib.error.HTTPError):
                    self.spawn(under, name)

        # -1 takes both caps away for the next child, past the defaults of 12
        # open children and 3 deep.
        settings.write_text(
            json.dumps({"subagents": {"maxOpenChildren": -1, "maxDepth": -1}})
        )
        self.spawn(parent, "second")
        lineage = [first]
        for depth in range(2, 5):
            child = self.spawn(lineage[-1], f"depth{depth}")
            self.assertEqual(child["depth"], depth)
            lineage.append(child["id"])
        self.assertEqual(self.snapshot(lineage[-1])["root_id"], parent)

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
                and latest_user(request) == marker
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

    def test_spawning_or_deleting_a_child_keeps_the_parent_validator(self):
        """A family's membership is not its configuration: a client holding the
        configuration it displayed may still change the model after agents come
        and go."""
        parent = self.app.session()
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            observed = response.headers["ETag"]
            response.read()
        before = self.app.family_revision(parent)
        child = self.spawn(parent)["id"]
        self.app.idle(child)
        self.app.idle(parent)
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            self.assertEqual(response.headers["ETag"], observed)
            response.read()
        self.assertNotEqual(self.app.family_revision(parent), before)
        with self.app.api(
            f"/sessions/{parent}?view=configuration",
            {"model": "changed-model"},
            method="PATCH",
            headers={"If-Match": observed},
        ) as response:
            self.assertEqual(json.load(response)["session"]["model"], "changed-model")
            edited = response.headers["ETag"]
        with self.app.api(f"/sessions/{child}?view=configuration") as response:
            child_etag = response.headers["ETag"]
        self.api(
            f"/sessions/{child}?view=configuration",
            method="DELETE",
            headers={"If-Match": child_etag},
        )
        with self.app.api(f"/sessions/{parent}?view=configuration") as response:
            self.assertEqual(response.headers["ETag"], edited)
            self.assertEqual(json.load(response)["model"], "changed-model")

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
            response.read()
            revision = response.headers["ETag"]
        family = self.app.family_revision(parent)
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
                f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={family}",
                method="DELETE",
                headers={"If-Match": revision},
            )
        self.assertEqual(caught.exception.code, 412)
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        answer = self.provider.script

        def held(request):
            if "hold subtree deletion" in latest_user(request):
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
            response.read()
            revision = response.headers["ETag"]
        family = self.app.family_revision(parent)
        outcome = self.api(
            f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={family}",
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
            response.read()
            revision = response.headers["ETag"]
        family = self.app.family_revision(parent)
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
                        f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={family}",
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
            response.read()
            revision = response.headers["ETag"]
        family = self.app.family_revision(parent)
        with sqlite3.connect(self.app.home / "albedo.sqlite") as db:
            db.execute(
                "CREATE TRIGGER fail_observed_deletion BEFORE DELETE ON sessions "
                f"WHEN OLD.id='{failed}' BEGIN SELECT RAISE(ABORT,'injected deletion failure'); END"
            )
        self.addCleanup(self._remove_deletion_failure)
        outcome = self.api(
            f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={family}",
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
                f"/sessions/{parent}?view=configuration&scope=subtree&family_revision={family}",
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
            user = latest_user(request)
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
            user = latest_user(request)
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

    def test_cancel_all_stops_every_running_turn_beneath_the_caller(self):
        entered = {"mid": threading.Event(), "leaf": threading.Event()}
        release = threading.Event()
        self.addCleanup(release.set)
        answer = self.provider.script

        def held(request):
            user = latest_user(request)
            for name, gate in entered.items():
                if f"hold {name}" in user:
                    gate.set()
                    release.wait(30)
                    return text("held turn ended")
            if request["messages"][-1].get("role") == "user" and user == "stop all":
                return python("print(sorted(await agents.cancel_all()))")
            return answer(request)

        self.provider.script = held
        parent = self.app.session()
        mid = self.spawn(parent, "mid", "hold mid")["id"]
        leaf = self.spawn(mid, "leaf", "hold leaf")["id"]
        for gate in entered.values():
            self.assertTrue(gate.wait(30), "a held turn never reached the provider")
        self.send(parent, "stop all")
        for session in (parent, mid, leaf):
            self.app.idle(session)
        self.assertFalse(release.is_set())
        result = next(
            json.loads(part["value"])
            for entry in reversed(self.app.history(parent)["items"])
            if entry["kind"] == "tool_result"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
        )
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(result["output"].strip(), str(sorted([mid, leaf])))

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
        # Each child's requests repeat its task, so count distinct letters.
        tasks = wait_for(
            lambda: (
                set(self.asked('kind="task">\ncross-provider'))
                if len(set(self.asked('kind="task">\ncross-provider'))) == 2
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

    def test_a_stalled_endpoint_never_stalls_the_daemon(self):
        # Spawning a child lists provider models, and a generic profile asks its
        # endpoint. That ran inside the registry, which every request waits on:
        # an endpoint that never answered held it for seconds per spawn, and
        # every request in the daemon failed with 503 meanwhile.
        parent = self.app.session()
        latencies, stop = [], threading.Event()

        def probe():
            while not stop.is_set():
                began = time.monotonic()
                try:
                    self.app.api("/server").close()
                    status = 200
                except urllib.error.HTTPError as error:
                    status = error.code
                latencies.append((time.monotonic() - began, status))
                time.sleep(0.05)

        prober = threading.Thread(target=probe)
        prober.start()
        try:
            # A bare model the parent's provider does not list: every profile
            # is asked, the stalled one included.
            made = self.spawn(
                parent, "scout", "scan", f"fixture-beta-{self.provider.route}"
            )
        finally:
            stop.set()
            prober.join()
        self.assertEqual(made["provider_profile"], self.beta)
        self.assertEqual([s for _, s in latencies if s != 200], [])
        self.assertLess(max(t for t, _ in latencies), 2, latencies)
        # The endpoint's failure is remembered: the next spawn does not wait.
        began = time.monotonic()
        self.spawn(parent, "scout-2", "scan", f"fixture-beta-{self.provider.route}")
        self.assertLess(time.monotonic() - began, 2)
        self.app.idle(made["id"])

    def test_request_to_missing_session_is_rejected(self):
        session = self.app.session()
        marker = "missing request " + operation_id()
        answer = self.provider.script

        def dispatch(request):
            if (
                request["messages"][-1].get("role") == "user"
                and latest_user(request) == marker
            ):
                return python(
                    "try:\n"
                    "    await mail.request('does-not-exist', 'body')\n"
                    "except Exception as error:\n"
                    "    print(type(error).__name__)\n"
                )
            return answer(request)

        self.provider.script = dispatch
        try:
            self.send(session, marker)
            self.app.idle(session)
        finally:
            self.provider.script = answer
        result = [
            entry
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result"
        ][-1]
        execution = next(
            json.loads(part["value"])
            for part in result["content"]
            if part["kind"] == "json" and part["field"] == "result"
        )
        self.assertEqual(execution["status"], "ok", execution)
        self.assertIn("WorkError", execution["output"])

    def test_start_peer_and_role_are_visible_in_sessions(self):
        parent = self.app.session()
        marker = "start peer " + operation_id()
        answer = self.provider.script

        def dispatch(request):
            if (
                request["messages"][-1].get("role") == "user"
                and latest_user(request) == marker
            ):
                return python(
                    "peer = await agents.start("
                    + repr("peer task")
                    + ", name="
                    + repr("peer")
                    + ", model="
                    + repr(f"{self.alpha}/fixture-alpha-{self.provider.route}")
                    + ", role="
                    + repr("research")
                    + ")\n"
                )
            return answer(request)

        self.provider.script = dispatch
        try:
            self.send(parent, marker)
            self.app.idle(parent)
        finally:
            self.provider.script = answer
        peers = [
            item
            for item in self.api("/sessions?scope=all")["items"]
            if item["name"] == "peer"
        ]
        self.assertEqual(len(peers), 1)
        peer = peers[0]
        self.assertEqual(peer["started_by"], parent)
        self.assertEqual(peer["role"], "research")
        self.app.idle(peer["id"])
        task = next(
            entry
            for entry in self.app.history(peer["id"])["items"]
            if (entry.get("mail") or {}).get("kind") == "request"
        )
        self.assertEqual(task["mail"]["sender_session_id"], parent)
        self.assertEqual(task["content"][0]["text"], "peer task")
        self.execute(
            parent,
            f"await agents.set_role('verification', id={peer['id']!r})",
        )
        self.assertEqual(self.snapshot(peer["id"])["role"], "verification")

    def test_started_peer_unreviewed_forward_and_open_requests(self):
        starter = self.app.session()
        task = "peer obligation task " + operation_id()
        answer = self.provider.script
        peer_open_sent = threading.Event()
        reviewed_sent = threading.Event()

        def dispatch(request):
            latest = latest_user(request)
            if peer_open_sent.is_set() and task in latest:
                return text("peer last words")
            if reviewed_sent.is_set() and "review request" in latest:
                return text("reviewed reply sent")
            if "You owe a reply to" in latest:
                return text("peer final words")
            if task in latest:
                peer_open_sent.set()
                return python(
                    "await asyncio.sleep(1)\n"
                    "opened = await mail.open()\n"
                    "assert len(opened['owed']) == 1, opened\n"
                    f"assert opened['owed'][0]['session'] == {starter!r}, opened\n"
                    "print('peer-open-ok')"
                )
            if "review request" in latest:
                reviewed_sent.set()
                return python(
                    f"await mail.submit({starter!r}, 'reviewed response')\n"
                    "print('reviewed-ok')"
                )
            return answer(request)

        self.provider.script = dispatch
        try:
            output = self.execute(
                starter,
                "peer = await agents.start("
                + repr(task)
                + ", name='worker', model="
                + repr(f"{self.alpha}/fixture-alpha-{self.provider.route}")
                + ")\n"
                "for _ in range(100):\n"
                "    opened = await mail.open()\n"
                "    if opened['awaiting']:\n"
                "        break\n"
                "    await asyncio.sleep(0.01)\n"
                "assert len(opened['awaiting']) == 1, opened\n"
                "assert opened['awaiting'][0]['session'] == peer.id, opened\n"
                "print(peer.id)",
            )
            peer = output.strip()
            self.app.idle(peer)
            forwarded = wait_for(lambda: self.asked('kind="unreviewed"') or None)[0]
            self.assertIn("peer final words", forwarded)
            self.assertEqual(len(self.asked("You owe a reply to")), 1)

            self.execute(starter, f"await mail.request({peer!r}, 'review request')")
            self.app.idle(peer)
            self.app.idle(starter)
            for session in (starter, peer):
                self.execute(
                    session,
                    "opened = await mail.open()\n"
                    "assert opened == {'owed': [], 'awaiting': []}, opened\n"
                    "print('open-clear')",
                )
        finally:
            self.provider.script = answer

    def test_only_starter_can_cancel_and_close_peer(self):
        starter = self.app.session()
        peer = self.execute(
            starter,
            "peer = await agents.start('authorization task', name='owned-peer', model="
            + repr(f"{self.alpha}/fixture-alpha-{self.provider.route}")
            + ")\n"
            "print(peer.id)",
        ).strip()
        self.app.idle(peer)
        stranger = self.app.session()
        output = self.execute(
            stranger,
            "target = await agents.get(" + repr(peer) + ")\n"
            "errors = []\n"
            "for action in (target.cancel, target.close):\n"
            "    try:\n"
            "        await action()\n"
            "    except Exception as error:\n"
            "        errors.append(str(error))\n"
            "assert len(errors) == 2, errors\n"
            "print('refused')",
        )
        self.assertIn("refused", output)
        self.execute(
            starter,
            "target = await agents.get(" + repr(peer) + ")\n"
            "await target.cancel()\n"
            "await target.close()",
        )
        self.assertTrue(self.snapshot(peer)["closed"])

    def test_root_request_reminds_and_forwards_unreviewed(self):
        sender = self.app.session()
        recipient = self.app.session()
        body = "plain root request " + operation_id()
        answer = self.provider.script

        def dispatch(request):
            if "You owe a reply to" in latest_user(request):
                return text("root final words: " + body)
            return answer(request)

        self.provider.script = dispatch
        try:
            self.execute(sender, f"await mail.request({recipient!r}, {body!r})")
            self.app.idle(recipient)
        finally:
            self.provider.script = answer
        forwarded = wait_for(lambda: self.asked('kind="unreviewed"') or None)[0]
        self.assertIn("root final words: " + body, forwarded)
        self.assertEqual(len(self.asked("You owe a reply to")), 1)
