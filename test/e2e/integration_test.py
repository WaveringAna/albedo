"""Daemon integration: provider binding, history, tools, workspaces, and recovery."""

import json
import os
from pathlib import Path
import sqlite3
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, python, text


def contents(item):
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    return " ".join(part.get("text", "") for part in content if isinstance(part, dict))


def script(request):
    inputs = request.get("messages", request.get("input", []))
    user = next(
        (contents(item) for item in reversed(inputs) if item.get("role") == "user"), ""
    )
    tools = sum(
        item.get("role") == "tool" or item.get("type") == "function_call_output"
        for item in inputs
    )
    if "continue from branch" in user:
        return text("finished")
    if "over 100 turns" in user:
        return text("finished") if tools >= 105 else python("1")
    if "workspace probe" in user:
        code = (
            "import os\nfrom pathlib import Path\n"
            "assert 'workspace_marker' not in globals()\n"
            "workspace_marker = os.getcwd()\nPath('cwd-probe').write_text(os.getcwd())"
        )
        done = (
            inputs[-1].get("role") == "tool"
            or inputs[-1].get("type") == "function_call_output"
        )
        return text("finished") if done else python(code)
    code = (
        "import asyncio, os\nfrom pathlib import Path\n"
        "Path('example.txt').write_text('hello\\n')\n"
        "saved = Path('example.txt').read_text()\n"
        "assert 'ALBEDO_API_KEY' not in os.environ\n"
        "assert 'ALBEDO_TOKEN' not in os.environ\n"
        f"await asyncio.sleep({30 if 'hang' in user else 2 if 'first task' in user else 0.4})\nlen(saved)"
    )
    return (
        text("finished")
        if tools
        else python(code, reasoning="reasoning about the task")
    )


class IntegrationTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(script)
        self.addCleanup(self.provider.close)

    def app_for(self, protocol, *, prepare=None, providers=None):
        app = Albedo(
            self.provider, protocol=protocol, prepare=prepare, providers=providers
        )
        app.__enter__()
        self.addCleanup(app.__exit__, None, None, None)
        return app

    def read(self, app, path):
        with app.api(path) as response:
            return json.load(response)

    def send(self, app, session, message):
        app.prompt(session, message).close()
        app.idle(session, timeout=90)

    def settings(self, app, protocol, active="alpha", **models):
        other = "responses" if protocol == "chat_completions" else "chat_completions"
        configured = {
            "alpha": ("alpha-2", models.get("alpha", "fixture-alpha"), protocol),
            "beta": ("beta-1", models.get("beta", "fixture-beta"), protocol),
            "gamma": ("gamma-1", models.get("gamma", "fixture-gamma"), other),
        }
        providers = {
            name: {
                "baseUrl": self.provider.url + f"/{name}/v1",
                "apiKey": key,
                "model": model,
                "protocol": binding,
            }
            for name, (key, model, binding) in configured.items()
        }
        (app.home / "config.json").write_text(
            json.dumps({"active": active, "providers": providers})
        )

    def records(self, start):
        return self.provider.requests[start:]

    def wait_for_request(self, start):
        deadline = time.monotonic() + 15
        while len(self.provider.requests) <= start and time.monotonic() < deadline:
            time.sleep(0.05)
        self.assertGreater(len(self.provider.requests), start)

    def assert_projected(self, record, protocol, users):
        items = record["request"][
            "messages" if protocol == "chat_completions" else "input"
        ]
        serialized = json.dumps(items)
        for user in users:
            self.assertIn(user, serialized)
        self.assertIn("finished", serialized)
        if protocol == "chat_completions":
            calls = [
                call["id"]
                for item in items
                if item.get("role") == "assistant"
                for call in item.get("tool_calls", [])
            ]
            outputs = [
                item["tool_call_id"] for item in items if item.get("role") == "tool"
            ]
        else:
            calls = [
                item["call_id"] for item in items if item.get("type") == "function_call"
            ]
            outputs = [
                item["call_id"]
                for item in items
                if item.get("type") == "function_call_output"
            ]
        self.assertTrue(any(call.startswith("fixture-call-") for call in calls))
        self.assertTrue(set(calls) & set(outputs))

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
        health = self.read(app, "/health")
        self.assertTrue(health["ok"])
        self.assertEqual(health["version"], 2)
        self.assertTrue(
            {"session_provider", "session_workspace"} <= set(health["capabilities"])
        )
        with self.assertRaises(urllib.error.HTTPError) as caught:
            app.api("/sessions", {"workspace": str(app.workspace)}).close()
        self.assertEqual(caught.exception.code, 400)
        self.assertIn("/login", json.load(caught.exception)["error"])
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
                session = app.session()
                info = next(
                    s for s in self.read(app, "/sessions") if s["id"] == session
                )
                self.assertEqual(
                    (info["provider"], info["title"]), ("alpha", "new session")
                )
                pid = app.connection["pid"]
                app.cli("sessions")
                self.assertEqual(
                    json.loads((app.home / "daemon.json").read_text())["pid"], pid
                )
                self.restart(app)
                info = next(s for s in self.read(app, "/sessions") if s["id"] == legacy)
                self.assertEqual(
                    (info["provider"], info["title"]),
                    ("default", "inspect the legacy workspace"),
                )

    def restart(self, app):
        app.restart(crash=True)

    def test_image_metadata_is_verified_and_only_metadata_is_exposed(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"
                attachment = {
                    "mimeType": "image/png",
                    "data": png,
                    "width": 2,
                    "height": 3,
                    "bytes": 24,
                }
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    app.api(
                        f"/sessions/{session}/events",
                        {
                            "content": "reject this",
                            "image": dict(attachment, width=4),
                        },
                    ).close()
                self.assertEqual(caught.exception.code, 409)
                start = len(self.provider.requests)
                app.api(
                    f"/sessions/{session}/events",
                    {
                        "content": "describe this image",
                        "image": attachment,
                    },
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
                    e["image"]
                    for e in app.events(session)
                    if e.get("type") == "user" and e.get("image")
                )
                self.assertEqual(
                    image,
                    {"mimeType": "image/png", "width": 2, "height": 3, "bytes": 24},
                )
                self.assertNotIn(png, json.dumps(image))

    def test_busy_messages_join_next_model_request_in_order(self):
        app = self.app_for("responses")
        session = app.session()
        start = len(self.provider.requests)
        with app.api(
            f"/sessions/{session}/events", {"content": "first task"}
        ) as response:
            self.assertFalse(json.load(response)["queued"])
        self.wait_for_request(start)
        with app.api(
            f"/sessions/{session}/events", {"content": "queued direction"}
        ) as response:
            self.assertTrue(json.load(response)["queued"])
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
                e.get("type") == "user" and e.get("text") == "queued direction"
                for e in app.events(session)
            )
        )

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
        before = app.events(session)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            app.prompt(session, "workspace probe after move").close()
        self.assertEqual(caught.exception.code, 409)
        failure = json.load(caught.exception)
        self.assertEqual(failure["code"], "workspace_missing")
        self.assertEqual(failure["workspace"], str(old))
        for invalid in ("relative", str(old), str(moved / "cwd-probe")):
            with self.assertRaises(urllib.error.HTTPError) as caught:
                app.api(
                    f"/sessions/{session}/workspace", {"workspace": invalid}
                ).close()
            self.assertEqual(caught.exception.code, 409)
        with app.api(
            f"/sessions/{session}/workspace", {"workspace": str(moved)}
        ) as response:
            self.assertEqual(json.load(response)["workspace"], str(moved))
        self.assertEqual(
            next(s for s in self.read(app, "/sessions") if s["id"] == session)[
                "workspace"
            ],
            str(moved),
        )
        self.assertEqual(json.loads((app.home / "daemon.json").read_text())["pid"], pid)
        self.send(app, session, "workspace probe after move")
        self.assertEqual(
            Path((moved / "cwd-probe").read_text()).resolve(), moved.resolve()
        )
        self.assertFalse(old.exists())
        after = app.events(session)
        self.assertEqual(
            [e for e in before if e.get("type") == "user"],
            [e for e in after if e.get("type") == "user"][:-1],
        )
        with sqlite3.connect(app.home / "albedo.sqlite") as db:
            self.assertEqual(
                db.execute(
                    "SELECT cwd FROM sessions WHERE id=?", (session,)
                ).fetchone()[0],
                str(moved),
            )
        self.restart(app)
        info = next(s for s in self.read(app, "/sessions") if s["id"] == session)
        self.assertEqual(info["workspace"], str(moved))

    @exclusive
    def test_tools_trace_detach_and_fork_checkpoint(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                app.prompt(session, "write and inspect a file").close()
                app.events(session)
                app.idle(session)
                events = app.events(session)
                self.assertEqual((app.workspace / "example.txt").read_text(), "hello\n")
                self.assertTrue(
                    any(
                        e.get("type") == "message" and e.get("text") == "finished"
                        for e in events
                    )
                )
                self.assertTrue(
                    any(
                        e.get("type") == "thinking"
                        and e.get("text") == "reasoning about the task"
                        for e in events
                    )
                )
                tool = next(e for e in events if e.get("type") == "tool")
                self.assertEqual(json.loads(tool["result"])["status"], "ok")
                self.assertTrue(
                    any(
                        a["kind"] == "read" and a["target"].endswith("example.txt")
                        for a in tool["trace"]["activities"]
                    )
                )
                self.assertTrue(
                    any(
                        c["path"].endswith("example.txt")
                        for c in tool["trace"]["changes"]
                    )
                )
                source = self.read(app, f"/sessions/{session}/tree?after=0&limit=100")
                items = source["items"]
                self.assertFalse(source["hasMore"])
                self.assertEqual(
                    {i["type"] for i in items}, {"user", "assistant", "tool"}
                )
                if protocol == "responses":
                    self.assertTrue(
                        any(i["preview"].startswith("[reasoning]") for i in items)
                    )
                checkpoint = next(i for i in items if i["preview"] == "call python")
                with app.api(
                    f"/sessions/{session}/fork", {"checkpoint": checkpoint["id"]}
                ) as response:
                    branch = json.load(response)
                self.assertEqual(branch["title"], "write and inspect a file")
                self.assertEqual(
                    (branch["provider"], branch["model"], branch["protocol"]),
                    ("fixture", "fixture-model", protocol),
                )
                branch_items = self.read(
                    app, f"/sessions/{branch['id']}/tree?after=0&limit=100"
                )["items"]
                self.assertEqual(
                    branch_items[-1]["preview"], "not executed after branch checkpoint"
                )
                self.assertEqual(
                    [i["preview"] for i in branch_items[:-1]],
                    [i["preview"] for i in items if i["id"] <= checkpoint["id"]],
                )
                start = len(self.provider.requests)
                self.send(app, branch["id"], "continue from branch")
                requests = self.records(start)
                self.assertEqual(len(requests), 1)
                self.assertTrue(
                    all(
                        "/chat/completions" in r["path"]
                        if protocol == "chat_completions"
                        else "/responses" in r["path"]
                        for r in requests
                    )
                )
                inputs = requests[0]["request"][
                    "messages" if protocol == "chat_completions" else "input"
                ]
                outputs = [
                    i
                    for i in inputs
                    if i.get("role") == "tool"
                    or i.get("type") == "function_call_output"
                ]
                self.assertEqual(
                    [i.get("content", i.get("output")) for i in outputs],
                    ["not executed after branch checkpoint"],
                )
                self.assertTrue(
                    any(
                        e.get("type") == "message" and e.get("text") == "finished"
                        for e in app.events(branch["id"])
                    )
                )
                self.assertEqual(
                    self.read(app, f"/sessions/{session}/tree?after=0&limit=100")[
                        "items"
                    ],
                    items,
                )
                self.assertEqual(
                    next(s for s in self.read(app, "/sessions") if s["id"] == session)[
                        "title"
                    ],
                    "write and inspect a file",
                )
                self.send(app, session, "review the result")
                self.assertEqual(
                    next(s for s in self.read(app, "/sessions") if s["id"] == session)[
                        "title"
                    ],
                    "review the result",
                )
                timestamps = [
                    (e["type"], e["text"], e.get("timestamp"))
                    for e in app.events(session)
                    if e.get("type") in ("user", "message")
                ]
                self.assertTrue(timestamps)
                self.assertTrue(
                    all(isinstance(stamp, int) for _, _, stamp in timestamps)
                )
                self.restart(app)
                self.assertEqual(
                    [
                        (e["type"], e["text"], e.get("timestamp"))
                        for e in app.events(session)
                        if e.get("type") in ("user", "message")
                    ],
                    timestamps,
                )

    @exclusive
    def test_provider_switch_projects_history_across_protocols_and_restart(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                self.settings(app, protocol)
                session = app.session()
                route = f"/sessions/{session}/commands"
                app.api(
                    route,
                    {
                        "name": "/model",
                        "args": {
                            "provider": "alpha",
                            "model": "initial-alpha",
                        },
                    },
                ).close()
                start = len(self.provider.requests)
                self.send(app, session, "build switch history")
                self.assertGreaterEqual(len(self.records(start)), 2)
                self.assertTrue(
                    all("/alpha/v1/" in r["path"] for r in self.records(start))
                )
                other = (
                    "responses"
                    if protocol == "chat_completions"
                    else "chat_completions"
                )
                for provider, model, expected in (
                    ("gamma", "chosen-gamma", other),
                    (None, "renamed-gamma", other),
                ):
                    args = {"model": model}
                    if provider:
                        args["provider"] = provider
                    with app.api(route, {"name": "/model", "args": args}) as response:
                        result = json.load(response)
                    self.assertEqual(
                        result,
                        {
                            "result": {
                                "provider": "gamma",
                                "model": model,
                                "protocol": expected,
                                "effort": None,
                            }
                        },
                    )
                    defaults = json.loads((app.home / "config.json").read_text())
                    self.assertEqual(defaults["active"], "gamma")
                    self.assertEqual(defaults["providers"]["gamma"]["model"], model)
                with app.api(
                    "/sessions", {"workspace": str(app.workspace)}
                ) as response:
                    default = json.load(response)
                self.assertEqual(
                    (default["provider"], default["model"]), ("gamma", "renamed-gamma")
                )
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    app.api(
                        route,
                        {
                            "name": "/model",
                            "args": {
                                "provider": "unknown",
                                "model": "wrong",
                            },
                        },
                    ).close()
                self.assertEqual(caught.exception.code, 409)
                start = len(self.provider.requests)
                self.send(app, session, "after first switch")
                gamma = self.records(start)
                self.assertTrue(gamma)
                self.assertTrue(
                    all(
                        "/gamma/v1/" in r["path"]
                        and r["model"] == "renamed-gamma"
                        and r["authorization"] == "Bearer gamma-1"
                        for r in gamma
                    )
                )
                self.assert_projected(
                    gamma[0], other, ["build switch history", "after first switch"]
                )
                with app.api(
                    route,
                    {
                        "name": "/model",
                        "args": {
                            "provider": "alpha",
                            "model": "returned-alpha",
                        },
                    },
                ) as response:
                    result = json.load(response)
                self.assertEqual(
                    result,
                    {
                        "result": {
                            "provider": "alpha",
                            "model": "returned-alpha",
                            "protocol": protocol,
                            "effort": None,
                        }
                    },
                )
                defaults = json.loads((app.home / "config.json").read_text())
                self.assertEqual(defaults["active"], "alpha")
                self.assertEqual(
                    defaults["providers"]["alpha"]["model"], "returned-alpha"
                )
                start = len(self.provider.requests)
                self.send(app, session, "after second switch")
                returned = self.records(start)
                self.assertTrue(returned)
                self.assertTrue(
                    all(
                        "/alpha/v1/" in r["path"] and r["model"] == "returned-alpha"
                        for r in returned
                    )
                )
                users = [
                    "build switch history",
                    "after first switch",
                    "after second switch",
                ]
                self.assert_projected(returned[0], protocol, users)
                info = next(
                    s for s in self.read(app, "/sessions") if s["id"] == session
                )
                self.assertEqual(
                    (info["provider"], info["model"], info["protocol"]),
                    ("alpha", "returned-alpha", protocol),
                )
                self.restart(app)
                start = len(self.provider.requests)
                self.send(app, session, "after persisted restart")
                restarted = self.records(start)
                self.assertTrue(restarted)
                self.assertTrue(
                    all(
                        "/alpha/v1/" in r["path"] and r["model"] == "returned-alpha"
                        for r in restarted
                    )
                )
                self.assert_projected(
                    restarted[0], protocol, users + ["after persisted restart"]
                )

    @exclusive
    def test_provider_config_reload_and_interrupt_recovery(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                self.settings(app, protocol)
                initial = json.loads((app.home / "config.json").read_text())
                initial["providers"]["alpha"]["apiKey"] = "alpha-1"
                (app.home / "config.json").write_text(json.dumps(initial))
                session = app.session()
                self.settings(app, protocol, active="beta")
                start = len(self.provider.requests)
                self.send(app, session, "write and inspect a file")
                alpha = self.records(start)
                self.assertTrue(alpha)
                self.assertTrue(
                    all(
                        "/alpha/v1/" in r["path"]
                        and r["authorization"] == "Bearer alpha-2"
                        and r["model"] == "fixture-alpha"
                        for r in alpha
                    )
                )
                second = app.session()
                info = next(s for s in self.read(app, "/sessions") if s["id"] == second)
                self.assertEqual(
                    (info["provider"], info["model"]), ("beta", "fixture-beta")
                )
                start = len(self.provider.requests)
                app.prompt(second, "hang").close()
                self.wait_for_request(start)
                for operation, body in (
                    ("workspace", {"workspace": str(app.root)}),
                    (
                        "commands",
                        {
                            "name": "/model",
                            "args": {
                                "provider": "gamma",
                                "model": "busy-rejected",
                            },
                        },
                    ),
                ):
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        app.api(f"/sessions/{second}/{operation}", body).close()
                    self.assertEqual(caught.exception.code, 409)
                info = next(s for s in self.read(app, "/sessions") if s["id"] == second)
                self.assertEqual(
                    (info["workspace"], info["provider"]), (str(app.workspace), "beta")
                )
                app.api(f"/sessions/{second}/interrupt", {}).close()
                app.idle(second)
                beta = self.records(start)
                self.assertTrue(beta)
                self.assertTrue(
                    all(
                        "/beta/v1/" in r["path"]
                        and r["authorization"] == "Bearer beta-1"
                        for r in beta
                    )
                )
                self.assertTrue(
                    any(e.get("type") == "user" for e in app.events(second))
                )
                third = app.session()
                app.prompt(third, "hang then recover").close()
                time.sleep(0.5)
                stamp = (app.workspace / "example.txt").stat().st_mtime_ns
                self.settings(
                    app, protocol, active="alpha", beta="changed-beta-default"
                )
                config = json.loads((app.home / "config.json").read_text())
                config["providers"]["beta"]["apiKey"] = "beta-2"
                (app.home / "config.json").write_text(json.dumps(config))
                start = len(self.provider.requests)
                self.restart(app)
                app.idle(third)
                restored = app.events(third)
                self.assertTrue(
                    any(
                        e.get("type") == "message" and e.get("text") == "finished"
                        for e in restored
                    )
                )
                resumed = self.records(start)
                self.assertTrue(resumed)
                self.assertTrue(
                    all(
                        "/beta/v1/" in r["path"]
                        and r["authorization"] == "Bearer beta-2"
                        and r["model"] == "fixture-beta"
                        for r in resumed
                    )
                )
                inputs = resumed[0]["request"][
                    "messages" if protocol == "chat_completions" else "input"
                ]
                note = [contents(i) for i in inputs if i.get("role") == "user"][-1]
                self.assertTrue(
                    note.startswith(
                        '<system-note origin="daemon restart">albedo restarted'
                    )
                )
                self.assertIn("<system-note>The python kernel", note)
                markers = [
                    e
                    for e in restored
                    if e.get("type") == "user" and e.get("source") == "daemon restart"
                ]
                self.assertEqual(len(markers), 1)
                self.assertTrue(markers[0]["text"].startswith("albedo restarted"))
                sessions = {s["id"]: s for s in self.read(app, "/sessions")}
                self.assertEqual(
                    (sessions[session]["provider"], sessions[session]["title"]),
                    ("alpha", "write and inspect a file"),
                )
                self.assertEqual(
                    (sessions[third]["provider"], sessions[third]["title"]),
                    ("beta", "hang then recover"),
                )
                self.assertEqual(
                    (app.workspace / "example.txt").stat().st_mtime_ns, stamp
                )
                self.assertTrue(
                    any(e.get("type") == "message" for e in app.events(session))
                )

    def test_more_than_hundred_tool_turns_complete(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                start = len(self.provider.requests)
                self.send(app, session, "continue for over 100 turns")
                self.assertEqual(len(self.records(start)), 106)
                events = app.events(session)
                self.assertEqual(sum(e.get("type") == "tool" for e in events), 105)
                self.assertTrue(
                    any(
                        e.get("type") == "message" and e.get("text") == "finished"
                        for e in events
                    )
                )


if __name__ == "__main__":
    unittest.main()
