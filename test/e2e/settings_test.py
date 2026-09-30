"""Daemon settings persistence, concurrent saves, and failed reload recovery."""

from concurrent.futures import ThreadPoolExecutor
import json
import stat
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

from harness import Albedo, Provider, exclusive, text

SERVER = Path(__file__).with_name("fake_mcp_server.py")


@exclusive
class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        for name in ("picker.json", "capabilities.json"):
            path = self.app.home / name
            prior = path.read_bytes() if path.exists() else None
            self.addCleanup(self.restore, path, prior)
        self.session = self.app.session()
        self.route = f"/sessions/{self.session}/settings"

    def restore(self, path, prior):
        if prior is None:
            path.unlink(missing_ok=True)
        else:
            path.write_bytes(prior)

    def request(self, path, body=None, method=None):
        with self.app.api(path, body, method=method) as response:
            return json.load(response)

    def snapshot(self):
        return self.request("/settings")

    def profile(self, **fields):
        return {
            "extension": "openai",
            "baseUrl": self.provider.url,
            "model": "fixture-model",
            "protocol": "responses",
            **fields,
        }

    def save_mcp(self, name, server, **secrets):
        return self.request(
            self.route + "/mcp/" + name,
            {"server": server, "secrets": secrets},
            "PUT",
        )

    def capability(
        self,
        kind="instructions",
        name="project:AGENTS.md",
        scope="session",
        enabled=False,
    ):
        return self.request(
            self.route + "/capabilities",
            {"kind": kind, "name": name, "scope": scope, "enabled": enabled},
        )

    def test_profiles_preserve_keys_and_unrelated_fields_and_redact_secrets(self):
        path = self.app.home / "config.json"
        config = json.loads(path.read_text())
        config["unrelated"] = {"kept": True}
        config["providers"]["settings-one"] = self.profile(custom="keep")
        path.write_text(json.dumps(config))
        self.request(
            "/settings/providers/settings-one",
            self.profile(apiKey="settings-secret"),
            "PUT",
        )
        self.request("/settings/providers/settings-one", self.profile(), "PUT")
        snapshot = self.snapshot()
        self.assertEqual(snapshot["profiles"]["active"], "settings-one")
        self.assertTrue(snapshot["profiles"]["providers"]["settings-one"]["hasKey"])
        self.assertNotIn("settings-secret", json.dumps(snapshot))
        stored = json.loads(path.read_text())
        self.assertNotIn("apiKey", stored["providers"]["settings-one"])
        self.assertEqual(stored["providers"]["settings-one"]["custom"], "keep")
        self.assertEqual(stored["unrelated"], {"kept": True})
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.request("/settings/providers/settings-two", self.profile(), "PUT")
        self.assertEqual(self.snapshot()["profiles"]["active"], "settings-two")
        self.request("/settings/providers/settings-one", method="DELETE")
        self.assertNotIn("settings-one", self.snapshot()["credentials"]["providers"])
        self.request("/settings/providers/settings-two", method="DELETE")
        snapshot = self.snapshot()
        self.assertEqual(
            snapshot["profiles"]["active"], min(snapshot["profiles"]["providers"])
        )

    def test_legacy_flat_provider_remains_available_after_save(self):
        path = self.app.home / "config.json"
        path.write_text(json.dumps(self.profile(apiKey="legacy-secret", custom="keep")))
        self.assertTrue(self.snapshot()["profiles"]["providers"]["default"]["hasKey"])
        self.request("/settings/providers/new-profile", self.profile(), "PUT")
        self.assertIn("default", self.snapshot()["profiles"]["providers"])
        self.assertEqual(json.loads(path.read_text())["custom"], "keep")
        self.assertNotIn("legacy-secret", json.dumps(self.snapshot()))

    def test_ui_updates_and_open_counts_survive_restart_and_session_deletion(self):
        session_path = f"/settings/ui/sessions/{self.session}"
        (self.app.home / "picker.json").write_text(
            json.dumps({"unrelated": {"keep": True}})
        )
        (self.app.home / "capabilities.json").write_text(
            json.dumps({"unrelated": {"keep": True}})
        )
        self.request("/settings/ui", {"thinking": True}, "PATCH")
        self.request(session_path, {"pinned": True, "archived": True}, "PATCH")
        for _ in range(3):
            self.request(session_path + "/open", method="POST")
        self.capability()
        self.app.restart()
        for name in ("picker.json", "capabilities.json"):
            self.assertEqual(
                json.loads((self.app.home / name).read_text())["unrelated"],
                {"keep": True},
            )
        prefs = self.snapshot()["ui"]
        self.assertTrue(prefs["thinking"])
        self.assertIn(self.session, prefs["pinned"])
        self.assertIn(self.session, prefs["archived"])
        self.assertEqual(prefs["opens"][self.session], 3)
        self.request(f"/sessions/{self.session}", method="DELETE")
        snapshot = self.snapshot()
        self.assertNotIn(self.session, snapshot["ui"]["pinned"])
        self.assertNotIn(self.session, snapshot["ui"]["archived"])
        self.assertNotIn(self.session, snapshot["ui"]["opens"])
        self.assertNotIn(self.session, snapshot["capabilities"]["sessions"])

    def test_concurrent_clients_preserve_independent_updates(self):
        ids = [self.session, self.app.session()]
        jobs = [
            lambda: self.request("/settings/ui", {"thinking": True}, "PATCH"),
            lambda: self.request("/settings/ui", {"tools": True}, "PATCH"),
        ]
        for session in ids:
            jobs.append(
                lambda session=session: self.request(
                    f"/settings/ui/sessions/{session}", {"pinned": True}, "PATCH"
                )
            )
        for _ in range(12):
            jobs.append(
                lambda: self.request(
                    f"/settings/ui/sessions/{ids[0]}/open", method="POST"
                )
            )
        with ThreadPoolExecutor(max_workers=6) as pool:
            list(pool.map(lambda job: job(), jobs))
        prefs = self.snapshot()["ui"]
        self.assertTrue(prefs["thinking"])
        self.assertTrue(prefs["tools"])
        self.assertTrue(set(ids) <= set(prefs["pinned"]))
        self.assertEqual(prefs["opens"][ids[0]], 12)

    def test_capability_inheritance_and_reload_failure_restore_previous_choice(self):
        (self.app.workspace / "AGENTS.md").write_text("unique settings instruction")
        self.capability(scope="global", enabled=False)
        self.capability(enabled=True)
        self.capability(enabled=None)
        caps = self.snapshot()["capabilities"]
        self.assertFalse(caps["global"]["instructions"]["project:AGENTS.md"])
        self.assertNotIn(
            "project:AGENTS.md", caps["sessions"][self.session]["instructions"]
        )
        self.app.prompt(self.session, "hello").close()
        self.app.idle(self.session)
        self.assertNotIn(
            "unique settings instruction",
            json.dumps(self.provider.requests[-1]["request"]),
        )
        self.request(
            f"/sessions/{self.session}/extensions", {"name": "mcp", "enabled": True}
        )
        self.capability(kind="mcp", name="broken", enabled=False)
        self.save_mcp("broken", {"type": "stdio", "command": "/missing/settings-mcp"})
        before = self.snapshot()
        with self.assertRaises(urllib.error.HTTPError) as failure:
            self.capability(kind="mcp", name="broken", enabled=True)
        self.assertEqual(failure.exception.code, 409)
        after = self.snapshot()
        self.assertEqual(after["mcp"], before["mcp"])
        self.assertEqual(after["capabilities"], before["capabilities"])

    def test_mcp_save_delete_and_failed_connection_restore_settings_and_credentials(
        self,
    ):
        self.request(
            f"/sessions/{self.session}/extensions", {"name": "mcp", "enabled": True}
        )
        server = {"type": "stdio", "command": sys.executable, "args": [str(SERVER)]}
        self.save_mcp(
            "settings-mcp", server, env={"FAKE_SECRET": "settings-mcp-secret"}
        )
        before = self.snapshot()
        self.assertNotIn("settings-mcp-secret", json.dumps(before))
        self.assertEqual(
            before["credentials"]["mcp"]["settings-mcp"]["env"], ["FAKE_SECRET"]
        )
        creds = (self.app.home / "creds.json").read_bytes()
        with self.assertRaises(urllib.error.HTTPError):
            self.save_mcp(
                "settings-mcp",
                dict(server, command="/missing/mcp"),
                env={"FAKE_SECRET": "changed-secret"},
            )
        self.assertEqual(self.snapshot()["mcp"], before["mcp"])
        self.assertEqual(
            json.loads((self.app.home / "creds.json").read_bytes()), json.loads(creds)
        )
        self.app.prompt(self.session, "still usable").close()
        self.app.idle(self.session)
        tools = self.provider.requests[-1]["request"]["tools"]
        self.assertTrue(
            any(
                tool.get("name", tool.get("function", {}).get("name", "")).startswith(
                    "mcp_settings_mcp_"
                )
                for tool in tools
            )
        )
        self.request(self.route + "/mcp/settings-mcp", method="DELETE")
        self.assertNotIn("settings-mcp", self.snapshot()["mcp"])
        self.assertNotIn("settings-mcp", self.snapshot()["credentials"]["mcp"])

    def test_malformed_documents_and_inputs_are_rejected_without_overwriting(self):
        cases = [
            (
                "picker.json",
                {"tools": "yes"},
                lambda: self.request("/settings/ui", {"tools": True}, "PATCH"),
            ),
            ("capabilities.json", {"global": {"skills": []}}, self.capability),
            (
                "extensions.json",
                {"mcp": {"servers": []}},
                lambda: self.save_mcp(
                    "sample", {"type": "http", "url": "http://localhost/mcp"}
                ),
            ),
            (
                "config.json",
                {"providers": []},
                lambda: self.request(
                    "/settings/providers/sample", self.profile(), "PUT"
                ),
            ),
        ]
        for name, malformed, save in cases:
            path = self.app.home / name
            prior = path.read_bytes() if path.exists() else None
            try:
                for content in (b'{"broken":', json.dumps(malformed).encode()):
                    path.write_bytes(content)
                    with self.assertRaises(urllib.error.HTTPError):
                        save()
                    self.assertEqual(path.read_bytes(), content)
                    with self.assertRaises(urllib.error.HTTPError):
                        self.snapshot()
            finally:
                self.restore(path, prior)
        invalid = [
            lambda: self.request("/settings/ui", {"tools": "yes"}, "PATCH"),
            lambda: self.request(
                "/settings/providers/sample", self.profile(protocol="wrong"), "PUT"
            ),
            lambda: self.request(
                self.route + "/capabilities",
                {"kind": "skills", "name": "sample", "scope": "global"},
            ),
            lambda: self.save_mcp(
                "sample", {"type": "http", "url": "file:///tmp/server"}
            ),
        ]
        for save in invalid:
            with self.assertRaises(urllib.error.HTTPError):
                save()

    def test_failed_persistence_reports_restoration_failure_and_keeps_old_files(self):
        before = {
            name: (self.app.home / name).read_bytes()
            if (self.app.home / name).exists()
            else None
            for name in ("config.json", "creds.json")
        }
        mode = stat.S_IMODE(self.app.home.stat().st_mode)
        try:
            self.app.home.chmod(0o500)
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.request(
                    "/settings/providers/failing",
                    self.profile(apiKey="must-not-save"),
                    "PUT",
                )
            self.assertIn("restoration failed", str(failure.exception))
        finally:
            self.app.home.chmod(mode)
        for name, content in before.items():
            path = self.app.home / name
            self.assertEqual(path.read_bytes() if path.exists() else None, content)

    def test_reload_and_global_extension_save_complete_when_they_overlap(self):
        other = self.app.session()
        marker = self.app.workspace / "mcp-started"
        script = (
            "import pathlib,time; "
            f"pathlib.Path({str(marker)!r}).touch(); "
            "time.sleep(1); "
            f"exec(pathlib.Path({str(SERVER)!r}).read_text())"
        )
        self.save_mcp(
            "slow-start",
            {"type": "stdio", "command": sys.executable, "args": ["-c", script]},
        )
        with ThreadPoolExecutor(max_workers=2) as pool:
            extension = pool.submit(
                self.request,
                f"/sessions/{other}/extensions",
                {"name": "mcp", "scope": "global", "enabled": True},
            )
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "MCP initialization did not start")
            capability = pool.submit(self.capability, name="overlapping-settings")
            extension.result(timeout=10)
            capability.result(timeout=10)

    def test_every_new_route_rejects_missing_authentication_and_browser_origins(self):
        routes = [
            ("GET", "/settings"),
            ("PUT", "/settings/providers/auth-check"),
            ("DELETE", "/settings/providers/auth-check"),
            ("PATCH", "/settings/ui"),
            ("PATCH", f"/settings/ui/sessions/{self.session}"),
            ("POST", f"/settings/ui/sessions/{self.session}/open"),
            ("POST", self.route + "/capabilities"),
            ("PUT", self.route + "/mcp/auth-check"),
            ("DELETE", self.route + "/mcp/auth-check"),
        ]
        for method, path in routes:
            for headers in (
                {},
                {
                    "Authorization": "Bearer " + self.app.connection["token"],
                    "Origin": "http://localhost",
                },
            ):
                request = urllib.request.Request(
                    self.app.base + path,
                    method=method,
                    headers=headers,
                )
                with self.assertRaises(urllib.error.HTTPError) as failure:
                    urllib.request.urlopen(request, timeout=10)
                self.assertEqual(failure.exception.code, 403, (method, path, headers))

    def test_busy_session_rejects_settings_before_persistence(self):
        entered = threading.Event()
        release = threading.Event()

        def script(_request):
            entered.set()
            release.wait(10)
            return text("finished")

        self.provider.script = script
        self.addCleanup(release.set)
        self.app.prompt(self.session, "wait").close()
        self.assertTrue(entered.wait(10))
        before = self.snapshot()["capabilities"]
        try:
            with self.assertRaises(urllib.error.HTTPError) as failure:
                self.capability()
            self.assertEqual(failure.exception.code, 409)
            self.assertEqual(self.snapshot()["capabilities"], before)
        finally:
            release.set()
            self.app.idle(self.session)


if __name__ == "__main__":
    unittest.main()
