"""Session setup, ingress failures, workspace repair, and image inspection."""

import json
from pathlib import Path
import sqlite3
import time
import urllib.error
import urllib.parse

from harness import exclusive, operation_id

from integration_fixture import IntegrationScenario


class IntegrationTest(IntegrationScenario):
    # exclusive: changes scheduler timing and installs a global database trigger
    @exclusive
    def test_scheduler_reports_a_failed_occurrence_write_and_retries(self):
        def prepare(app):
            app.env["ALBEDO_SCHEDULE_TICK_MS"] = "50"

        app = self.app_for("chat_completions", prepare=prepare)
        session = app.session()
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            db.execute(
                "CREATE TRIGGER reject_advance BEFORE DELETE ON schedules "
                "BEGIN SELECT RAISE(FAIL, 'fixture advance failed'); END"
            )
            db.execute(
                "INSERT INTO schedules(session,kind,prompt,next_at) VALUES(?,'once',?,0)",
                (session, "scheduled fixture"),
            )
        deadline = time.monotonic() + 15
        while "fixture advance failed" not in (app.home / "daemon.log").read_text():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.05)
        self.assertIn(
            "schedule occurrence could not be advanced",
            (app.home / "daemon.log").read_text(),
        )
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            self.assertEqual(
                db.execute("SELECT COUNT(*) FROM schedules").fetchone()[0], 1
            )
            db.execute("DROP TRIGGER reject_advance")
        while True:
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                if db.execute("SELECT COUNT(*) FROM schedules").fetchone()[0] == 0:
                    break
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.05)
        app.idle(session)
        self.assertTrue(self.provider.requests)

    # exclusive: renames the global session_family table
    @exclusive
    def test_deletion_refuses_a_failed_child_lookup(self):
        app = self.app_for("chat_completions")
        session = app.session()
        with app.api(f"/sessions/{session}?view=configuration") as response:
            configuration = json.load(response)
            etag = response.headers["ETag"]
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            db.execute("ALTER TABLE session_family RENAME TO unavailable_family")
        for scope in ("leaf", "subtree"):
            with self.subTest(scope=scope):
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    app.api(
                        f"/sessions/{session}?view=configuration&scope={scope}"
                        f"&family_revision={configuration['family_revision']}",
                        method="DELETE",
                        headers={"If-Match": etag},
                    ).close()
                self.assertGreaterEqual(caught.exception.code, 400)
                with sqlite3.connect(app.home / "albedo.sqlite") as db:
                    self.assertIsNotNone(
                        db.execute(
                            "SELECT id FROM sessions WHERE id=?", (session,)
                        ).fetchone()
                    )
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            db.execute("ALTER TABLE unavailable_family RENAME TO session_family")
        with app.api(
            f"/sessions/{session}?view=configuration&scope=subtree"
            f"&family_revision={configuration['family_revision']}",
            method="DELETE",
            headers={"If-Match": etag},
        ) as response:
            self.assertEqual(json.load(response)["deleted_ids"], [session])

    # exclusive: tests unconfigured startup and legacy migration
    @exclusive
    def test_unconfigured_startup_and_legacy_provider_migration(self):
        def prepare(app):
            workspace = app.root / "legacy-workspace"
            workspace.mkdir(exist_ok=True)
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute(
                    "CREATE TABLE sessions(id TEXT PRIMARY KEY,cwd TEXT NOT NULL,model TEXT NOT NULL,protocol TEXT NOT NULL,stage TEXT NOT NULL DEFAULT 'idle')"
                )
                for protocol in ("responses", "chat_completions"):
                    db.execute(
                        "INSERT INTO sessions(id,cwd,model,protocol) VALUES(?,?,?,?)",
                        (
                            "legacy-" + protocol,
                            str(workspace),
                            "legacy-model",
                            protocol,
                        ),
                    )

        app = self.app_for("responses", prepare=prepare, providers={})
        health = self.read(app, "/server")
        self.assertEqual(health["state"], "ready")
        unconfigured = self.read(app, "/sessions?scope=all")["items"]
        self.assertEqual(
            {info["id"] for info in unconfigured},
            {"legacy-responses", "legacy-chat_completions"},
        )
        for info in unconfigured:
            self.assertIsNone(info["provider_profile"])
            snapshot = self.read(app, f"/sessions/{info['id']}?tail=0")
            self.assertIsNone(snapshot["provider_profile"])
            resource = snapshot["configuration_resource"]
            self.assertIsNone(resource["value"]["provider_profile"])
            self.assertIsNone(self.read(app, resource["url"])["provider_profile"])
        with self.assertRaises(urllib.error.HTTPError) as caught:
            app.api(
                f"/sessions/{operation_id()}",
                {"kind": "new", "workspace": str(app.workspace)},
                method="PUT",
                headers={"If-None-Match": "*"},
            ).close()
        self.assertEqual(caught.exception.code, 409)
        self.assertIn("/login", json.load(caught.exception)["detail"])
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                legacy = "legacy-" + protocol
                self.settings(app, protocol)
                config = json.loads((app.home / "config.json").read_text())
                config["providers"]["default"] = {
                    "baseUrl": self.provider.url + "/legacy/v1",
                    "apiKey": "legacy-key",
                    "model": "legacy-model",
                    "protocol": protocol,
                }
                (app.home / "config.json").write_text(json.dumps(config))
                start = len(self.provider.requests)
                self.send(app, legacy, "inspect the legacy workspace")
                requests = self.records(start)
                self.assertTrue(requests)
                self.assertTrue(all("/legacy/v1/" in r["path"] for r in requests))
                self.assertTrue(
                    all(r["authorization"] == "Bearer legacy-key" for r in requests)
                )
                session = self.default_session(app)
                info = next(
                    s
                    for s in self.read(app, "/sessions?scope=all")["items"]
                    if s["id"] == session
                )
                self.assertEqual(
                    (info["provider_profile"], info["automatic_name"]),
                    ("alpha", "new session"),
                )
                pid = app.connection["pid"]
                app.cli("sessions")
                self.assertEqual(
                    json.loads((app.home / "daemon.json").read_text())["pid"], pid
                )
                self.restart(app)
                info = next(
                    s
                    for s in self.read(app, "/sessions?scope=all")["items"]
                    if s["id"] == legacy
                )
                self.assertEqual(
                    (info["provider_profile"], info["automatic_name"]),
                    ("default", "inspect the legacy workspace"),
                )

    def test_image_metadata_is_verified_and_only_metadata_is_exposed(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    app.api(
                        f"/sessions/{session}/inputs/{operation_id()}",
                        {
                            "kind": "message",
                            "text": "reject this",
                            "image": {"mime_type": "image/png", "data": "not base64"},
                        },
                        method="PUT",
                    ).close()
                self.assertEqual(caught.exception.code, 400)
                start = len(self.provider.requests)
                app.api(
                    f"/sessions/{session}/inputs/{operation_id()}",
                    {
                        "kind": "message",
                        "text": "describe this image",
                        "image": {"mime_type": "image/png", "data": png},
                    },
                    method="PUT",
                ).close()
                app.idle(session)
                self.send(app, session, "confirm image history")
                requests = self.records(start)
                self.assertEqual(len(requests), 3)
                self.assertTrue(
                    all(
                        "data:image/png;base64," + png in json.dumps(r["request"])
                        for r in requests
                    )
                )
                image = next(
                    part["image"]
                    for e in self.history(app, session)
                    for part in e["content"]
                    if part["kind"] == "image"
                )
                self.assertEqual(
                    (
                        image["mime_type"],
                        image["width"],
                        image["height"],
                        image["original_bytes"],
                    ),
                    ("image/png", 2, 3, 24),
                )
                self.assertNotIn(png, json.dumps(image))

    def test_busy_messages_join_next_model_request_in_order(self):
        app = self.app_for("responses")
        session = app.session()
        start = len(self.provider.requests)
        app.prompt(session, "first task").close()
        self.wait_for_request(start)
        app.prompt(session, "queued direction").close()
        app.prompt(session, "another direction").close()
        app.idle(session)
        requests = self.records(start)
        self.assertEqual(len(requests), 2)
        first, second = (json.dumps(r["request"]) for r in requests)
        self.assertNotIn("queued direction", first)
        self.assertIn("queued direction", second)
        self.assertIn("another direction", second)
        self.assertLess(
            second.index("queued direction"), second.index("another direction")
        )
        self.assertTrue(
            any(
                e["kind"] == "user" and self.entry_text(e) == "queued direction"
                for e in self.history(app, session)
            )
        )

    # exclusive: restarts the daemon
    @exclusive
    def test_workspace_repair_validates_path_and_preserves_history(self):
        app = self.app_for("responses")
        old = app.root / "original-workspace"
        old.mkdir()
        moved = app.root / "moved-workspace"
        session = app.session(old)
        self.send(app, session, "workspace probe before move")
        self.assertEqual(Path((old / "cwd-probe").read_text()).resolve(), old.resolve())
        old.rename(moved)
        pid = app.connection["pid"]
        before = self.history(app, session)
        identity = operation_id()
        app.api(
            f"/sessions/{session}/inputs/{identity}",
            {"kind": "message", "text": "workspace probe after move"},
            method="PUT",
        ).close()
        receipt = self.read(app, f"/sessions/{session}/inputs/{identity}")
        self.assertEqual(receipt["delivery"], "pending")
        for invalid in ("relative", str(old), str(moved / "cwd-probe")):
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.change(app, session, {"workspace": invalid})
            self.assertIn(caught.exception.code, (400, 409))
        self.change(app, session, {"workspace": str(moved)})
        self.assertEqual(
            self.read(app, f"/sessions/{session}")["workspace"], str(moved)
        )
        self.assertEqual(json.loads((app.home / "daemon.json").read_text())["pid"], pid)
        app.idle(session, timeout=35)
        receipt = self.read(app, f"/sessions/{session}/inputs/{identity}")
        self.assertEqual(receipt["delivery"], "committed")
        self.assertEqual(
            Path((moved / "cwd-probe").read_text()).resolve(), moved.resolve()
        )
        self.assertFalse(old.exists())
        after = self.history(app, session)
        self.assertEqual(
            [e for e in before if e["kind"] == "user"],
            [e for e in after if e["kind"] == "user"][:-1],
        )
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            self.assertEqual(
                db.execute(
                    "SELECT cwd FROM sessions WHERE id=?", (session,)
                ).fetchone()[0],
                str(moved),
            )
        self.restart(app)
        self.assertEqual(
            self.read(app, f"/sessions/{session}")["workspace"], str(moved)
        )
