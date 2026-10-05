"""Provider changes preserve history and confirmed configuration across restart."""

import json
import time
import urllib.error
import urllib.parse

from harness import exclusive

from integration_support import IntegrationScenario, contents


class ProviderBindingTests(IntegrationScenario):
    # exclusive: changes global provider settings and restarts the daemon
    @exclusive
    def test_provider_switch_projects_history_across_protocols_and_restart(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                self.settings(app, protocol)
                session = self.default_session(app)
                self.change(
                    app,
                    session,
                    {"provider_profile": "alpha", "model": "initial-alpha"},
                )
                self.send(app, session, "build switch history")
                other = (
                    "responses"
                    if protocol == "chat_completions"
                    else "chat_completions"
                )
                for fields in (
                    {"provider_profile": "gamma", "model": "chosen-gamma"},
                    {"model": "renamed-gamma"},
                ):
                    self.change(app, session, fields)
                selected = self.read(app, f"/sessions/{session}")
                self.assertEqual(
                    (selected["provider_profile"], selected["model"]),
                    ("gamma", "renamed-gamma"),
                )
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    self.change(
                        app, session, {"provider_profile": "unknown", "model": "wrong"}
                    )
                self.assertIn(caught.exception.code, (400, 409))
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
                # Per-session selection does not silently rewrite global defaults.
                default = self.read(app, f"/sessions/{self.default_session(app)}")
                self.assertEqual(
                    (default["provider_profile"], default["model"]),
                    ("alpha", "fixture-alpha"),
                )
                self.change(
                    app,
                    session,
                    {"provider_profile": "alpha", "model": "returned-alpha"},
                )
                start = len(self.provider.requests)
                self.send(app, session, "after second switch")
                returned = self.records(start)
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
                self.restart(app)
                start = len(self.provider.requests)
                self.send(app, session, "after persisted restart")
                restarted = self.records(start)
                self.assertTrue(
                    all(
                        "/alpha/v1/" in r["path"] and r["model"] == "returned-alpha"
                        for r in restarted
                    )
                )
                self.assert_projected(
                    restarted[0], protocol, users + ["after persisted restart"]
                )

    # exclusive: changes global provider settings and restarts the daemon
    @exclusive
    def test_provider_config_reload_and_interrupt_recovery(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                self.settings(app, protocol)
                initial = json.loads((app.home / "config.json").read_text())
                initial["providers"]["alpha"]["apiKey"] = "alpha-1"
                (app.home / "config.json").write_text(json.dumps(initial))
                session = self.default_session(app)
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
                second = self.default_session(app)
                info = next(
                    s
                    for s in self.read(app, "/sessions?scope=all")["items"]
                    if s["id"] == second
                )
                self.assertEqual(
                    (info["provider_profile"], info["model"]), ("beta", "fixture-beta")
                )
                start = len(self.provider.requests)
                app.prompt(second, "hang").close()
                self.wait_for_request(start)
                for fields in (
                    {"workspace": str(app.root)},
                    {"provider_profile": "gamma", "model": "busy-rejected"},
                ):
                    with self.assertRaises(urllib.error.HTTPError) as caught:
                        self.change(app, second, fields)
                    self.assertEqual(caught.exception.code, 409)
                info = next(
                    s
                    for s in self.read(app, "/sessions?scope=all")["items"]
                    if s["id"] == second
                )
                self.assertEqual(
                    (info["workspace"], info["provider_profile"]),
                    (str(app.workspace), "beta"),
                )
                captured = self.read(app, f"/sessions/{second}?tail=0")
                app.api(
                    f"/sessions/{second}/interrupt",
                    {
                        "run_id": captured["status"]["run_id"],
                        "through_input_order": captured["input_order"],
                    },
                ).close()
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
                    any(e["kind"] == "user" for e in self.history(app, second))
                )
                third = self.default_session(app)
                app.prompt(third, "hang then recover").close()
                ready = app.workspace / "recovery-started"
                deadline = time.monotonic() + 15
                while not ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                self.assertTrue(ready.exists(), "recovery tool did not start")
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
                restored = self.history(app, third)
                self.assertTrue(
                    any(
                        e["kind"] == "assistant" and self.entry_text(e) == "finished"
                        for e in restored
                    ),
                    {
                        "history": restored,
                        "session": self.read(app, f"/sessions/{third}?tail=0"),
                    },
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
                # The detached kernel outlives the crash: it reattached with
                # its namespace, so the notice says that, not a reset.
                self.assertIn("<system-note>The python kernel reattached", note)
                self.assertNotIn("<system-note>The python kernel got reset", note)
                markers = [
                    e
                    for e in restored
                    if e["kind"] == "note" and "albedo restarted" in self.entry_text(e)
                ]
                self.assertEqual(len(markers), 1)
                self.assertTrue(
                    self.entry_text(markers[0]).startswith("albedo restarted")
                )
                sessions = {
                    s["id"]: s for s in self.read(app, "/sessions?scope=all")["items"]
                }
                self.assertEqual(
                    (
                        sessions[session]["provider_profile"],
                        sessions[session]["automatic_name"],
                    ),
                    ("alpha", "write and inspect a file"),
                )
                self.assertEqual(
                    (
                        sessions[third]["provider_profile"],
                        sessions[third]["automatic_name"],
                    ),
                    ("beta", "hang then recover"),
                )
                self.assertEqual(
                    (app.workspace / "example.txt").stat().st_mtime_ns, stamp
                )
                self.assertTrue(
                    any(e["kind"] == "assistant" for e in self.history(app, session))
                )
