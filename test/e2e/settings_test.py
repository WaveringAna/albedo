"""Conditional settings saves, independent writers, and prepared-context recovery."""

from concurrent.futures import ThreadPoolExecutor
import errno
import json
import os
from pathlib import Path
import stat
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request

from harness import Albedo, Provider, exclusive, operation_id, text

SERVER = Path(__file__).with_name("fake_mcp_server.py")


class SettingsTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider).__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def read(self, path):
        with self.app.api(path) as response:
            return json.load(response)

    def group(self, group):
        return self.read("/settings?group=" + group)

    def patch(self, group, fields, *, etag=None):
        route = "/settings?group=" + group
        if etag is None:
            with self.app.api(route) as response:
                json.load(response)
                etag = response.headers["ETag"]
        with self.app.api(
            route, fields, method="PATCH", headers={"If-Match": etag}
        ) as response:
            return json.load(response)

    def change(self, fields, session=None):
        route = f"/sessions/{session or self.session}?view=configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        with self.app.api(
            route, fields, method="PATCH", headers={"If-Match": etag}
        ) as response:
            return json.load(response)

    def profile(self, **fields):
        return {
            "extension": "openai",
            "endpoint": self.provider.url,
            "model": "fixture-model",
            "protocol": "responses",
            **fields,
        }

    def discovery(self, session=None):
        return self.read(f"/sessions/{session or self.session}/catalog")["discovery"]

    def commands(self):
        return self.read(f"/sessions/{self.session}/catalog")["loaded"]["commands"]

    def choice(self, name, *, kind="instructions", enabled=False, global_default=False):
        catalog = self.discovery()
        row = next(
            row for row in catalog["candidates"] if row["preference_key"] == name
        )
        if global_default:
            return self.patch(
                "capabilities",
                {
                    "catalog_session_id": self.session,
                    "catalog_revision": catalog["revision"],
                    "choices": {row["id"]: enabled},
                },
            )
        return self.change(
            {
                "catalog_revision": catalog["revision"],
                "selection": {kind: {row["id"]: enabled}},
            }
        )

    def reload(self, *, session=None):
        with self.app.api(
            f"/sessions/{session or self.session}/reload", {"target": "session"}
        ) as response:
            return json.load(response)

    def turn(self, prompt="inspect settings", *, session=None):
        self.app.prompt(session or self.session, prompt).close()
        self.app.idle(session or self.session)
        return json.dumps(self.provider.requests[-1]["request"])

    def write_skill(self, name, description):
        path = self.app.workspace / ".albedo" / "skills" / name / "SKILL.md"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"---\nname: {name}\ndescription: {description}\n---\nbody\n")
        return path

    # exclusive: saves global profiles and credentials
    @exclusive
    def test_profiles_preserve_keys_unrelated_fields_and_redact_secrets(self):
        path = self.app.home / "config.json"
        config = json.loads(path.read_text())
        config["unrelated"] = {"kept": True}
        config["providers"]["settings-one"] = {
            "extension": "openai",
            "baseUrl": self.provider.url,
            "model": "fixture-model",
            "protocol": "responses",
            "custom": "keep",
        }
        path.write_text(json.dumps(config))
        self.patch(
            "providers",
            {
                "default_profile": "settings-one",
                "profiles": {"settings-one": {"api_key": "settings-secret"}},
            },
        )
        self.patch(
            "providers", {"profiles": {"settings-one": {"model": "replacement"}}}
        )
        snapshot = self.read("/settings")
        self.assertEqual(snapshot["providers"]["default_profile"], "settings-one")
        self.assertTrue(snapshot["providers"]["profiles"]["settings-one"]["has_key"])
        self.assertNotIn("settings-secret", json.dumps(snapshot))
        stored = json.loads(path.read_text())
        self.assertNotIn("apiKey", stored["providers"]["settings-one"])
        self.assertEqual(stored["providers"]["settings-one"]["custom"], "keep")
        self.assertEqual(stored["unrelated"], {"kept": True})
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.patch(
            "providers",
            {"default_profile": self.app.profile, "profiles": {"settings-one": None}},
        )
        self.assertNotIn("settings-one", self.group("providers")["profiles"])
        self.assertNotIn(
            "settings-one",
            json.loads((self.app.home / "creds.json").read_text())["providers"],
        )

    # exclusive: stored-data compatibility remains independent of the HTTP protocol
    @exclusive
    def test_legacy_flat_provider_remains_available_after_save(self):
        path = self.app.home / "config.json"
        path.write_text(
            json.dumps(
                {
                    "extension": "openai",
                    "baseUrl": self.provider.url,
                    "model": "legacy",
                    "protocol": "responses",
                    "apiKey": "legacy-secret",
                    "custom": "keep",
                }
            )
        )
        self.assertTrue(self.group("providers")["profiles"]["default"]["has_key"])
        self.patch("providers", {"profiles": {"new-profile": self.profile()}})
        self.assertIn("default", self.group("providers")["profiles"])
        self.assertEqual(json.loads(path.read_text())["custom"], "keep")
        self.assertNotIn("legacy-secret", json.dumps(self.read("/settings")))

    # exclusive: partial profile writes retain omitted credentials
    @exclusive
    def test_provider_partial_saves_preserve_omitted_key_and_explicit_null_removes_it(
        self,
    ):
        self.patch(
            "providers",
            {"profiles": {"normalization": self.profile(api_key="profile-secret")}},
        )
        self.patch("providers", {"profiles": {"normalization": {"model": "changed"}}})
        profile = self.group("providers")["profiles"]["normalization"]
        self.assertEqual(profile["model"], "changed")
        self.assertTrue(profile["has_key"])
        self.patch("providers", {"profiles": {"normalization": {"api_key": None}}})
        self.assertFalse(
            self.group("providers")["profiles"]["normalization"]["has_key"]
        )
        self.patch(
            "providers",
            {
                "profiles": {
                    "subscription": {
                        "extension": "codex",
                        "protocol": "responses",
                        "model": "fixture",
                    }
                }
            },
        )
        self.assertIsNone(
            self.group("providers")["profiles"]["subscription"]["endpoint"]
        )

    # exclusive: preserves settings files across malformed candidates
    @exclusive
    def test_invalid_provider_profiles_leave_settings_and_credentials_untouched(self):
        paths = [self.app.home / name for name in ("config.json", "creds.json")]
        before = [path.read_bytes() if path.exists() else None for path in paths]
        invalid = [
            [],
            {},
            self.profile(model=""),
            self.profile(model="fixture\x00model"),
            self.profile(protocol="wrong"),
            self.profile(extension=""),
            self.profile(endpoint="file:///tmp/model"),
            self.profile(endpoint="https://user@example.com"),
            self.profile(endpoint="https://example.com?bad"),
            self.profile(endpoint="https://example.com:invalid"),
            self.profile(api_key="secret\nkey"),
            self.profile(image_edge=0),
            self.profile(ignored="unexpected"),
        ]
        for profile in invalid:
            with (
                self.subTest(profile=profile),
                self.assertRaises(urllib.error.HTTPError) as caught,
            ):
                self.patch("providers", {"profiles": {"invalid-profile": profile}})
            self.assertEqual(caught.exception.code, 400)
            self.assertEqual(
                [path.read_bytes() if path.exists() else None for path in paths], before
            )

    # exclusive: global group revisions are independent, session visits are idempotent
    @exclusive
    def test_concurrent_writers_reject_stale_group_and_preserve_independent_groups(
        self,
    ):
        with self.app.api("/settings?group=ui") as response:
            json.load(response)
            etag = response.headers["ETag"]
        with ThreadPoolExecutor(max_workers=2) as pool:
            jobs = [
                pool.submit(self.patch, "ui", fields, etag=etag)
                for fields in ({"thinking": True}, {"tools": True})
            ]
            outcomes = []
            for job in jobs:
                try:
                    outcomes.append(job.result())
                except urllib.error.HTTPError as error:
                    outcomes.append(error.code)
        self.assertEqual(outcomes.count(412), 1)
        self.patch("ui", {"thinking": True, "tools": True})
        ids = [self.session, self.app.session()]
        with ThreadPoolExecutor(max_workers=4) as pool:
            list(
                pool.map(
                    lambda sid: self.change({"preferences": {"pinned": True}}, sid), ids
                )
            )
            visits = [operation_id() for _ in range(12)]

            def visit(identity):
                with self.app.api(
                    f"/sessions/{ids[0]}/visits/{identity}", {}, method="PUT"
                ) as response:
                    return json.load(response)

            receipts = list(pool.map(visit, visits))
        # After other visits, a lost acknowledgement returns its original count.
        first = next(receipt for receipt in receipts if receipt["opens"] == 1)
        self.assertEqual(visit(first["visit_id"]), first)
        self.assertEqual(self.read(f"/sessions/{ids[0]}")["preferences"]["opens"], 12)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.app.api(
                f"/sessions/{ids[1]}/visits/{first['visit_id']}", {}, method="PUT"
            )
        self.assertEqual(caught.exception.code, 409)
        self.assertEqual(self.read(f"/sessions/{ids[1]}")["preferences"]["opens"], 0)
        self.assertTrue(
            all(self.read(f"/sessions/{sid}")["preferences"]["pinned"] for sid in ids)
        )
        self.assertTrue(self.group("ui")["thinking"])
        self.assertTrue(self.group("ui")["tools"])

    def test_session_configuration_is_one_conditional_candidate(self):
        self.write_skill("compound-config", "COMPOUND_CONFIG_SKILL")
        self.assertIn("COMPOUND_CONFIG_SKILL", self.turn())
        discovery = self.discovery()
        skill = next(
            row
            for row in discovery["candidates"]
            if row["preference_key"] == "compound-config"
        )
        route = f"/sessions/{self.session}?view=configuration"
        with self.app.api(route) as response:
            before = json.load(response)
            observed = response.headers["ETag"]
        model = before["model"] or self.read(f"/sessions/{self.session}")["model"]
        candidate = {
            "name": "must not partially save",
            "preferences": {"pinned": True, "archived": True},
            "model": model,
            "effort": "unsupported-effort",
            "selection": {"skills": {skill["id"]: False}},
            "catalog_revision": discovery["revision"],
        }
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.app.api(
                route, candidate, method="PATCH", headers={"If-Match": observed}
            )
        self.assertEqual(caught.exception.code, 400)
        self.assertEqual(self.read(route), before)
        self.assertIn(
            "/compound-config", {row["slash_name"] for row in self.commands()}
        )

        del candidate["effort"]
        barrier = threading.Barrier(3)

        def save(name):
            barrier.wait()
            try:
                with self.app.api(
                    route,
                    {**candidate, "name": name},
                    method="PATCH",
                    headers={"If-Match": observed},
                ) as response:
                    return response.status, json.load(response)
            except urllib.error.HTTPError as error:
                return error.code, json.load(error)

        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [
                pool.submit(save, name)
                for name in ("first compound writer", "second compound writer")
            ]
            barrier.wait()
            outcomes = [future.result(timeout=10) for future in futures]
        self.assertEqual(sorted(status for status, _ in outcomes), [200, 412])
        winner = next(body for status, body in outcomes if status == 200)
        saved = self.read(route)
        self.assertEqual(saved, winner["resource"]["value"])
        self.assertTrue(saved["preferences"]["pinned"])
        self.assertTrue(saved["preferences"]["archived"])
        self.assertEqual(saved["model"], model)
        # Desired choices do not silently rewrite prepared commands.
        self.assertIn(
            "/compound-config", {row["slash_name"] for row in self.commands()}
        )
        self.assertEqual(self.reload()["session"]["state"], "applied")
        self.assertNotIn(
            "/compound-config", {row["slash_name"] for row in self.commands()}
        )
        # Null entry and null map both clear overrides back to inheritance.
        self.choice("compound-config", kind="skills", enabled=None)
        self.assertEqual(self.reload()["session"]["state"], "applied")
        self.assertIn("COMPOUND_CONFIG_SKILL", self.turn())
        self.choice("compound-config", kind="skills", enabled=False)
        self.change(
            {
                "selection": {"skills": None},
                "catalog_revision": self.discovery()["revision"],
            }
        )
        self.assertEqual(self.read(route)["selection"]["skills"], {})
        self.change(
            {
                "selection": {"skills": {}},
                "catalog_revision": self.discovery()["revision"],
            }
        )
        self.assertEqual(self.read(route)["selection"]["skills"], {})
        self.assertEqual(self.reload()["session"]["state"], "applied")
        self.assertIn("COMPOUND_CONFIG_SKILL", self.turn())

    # exclusive: restarts and deletes a session with persisted preferences
    @exclusive
    def test_preferences_and_visits_survive_restart_and_session_deletion(self):
        picker = self.app.home / "picker.json"
        picker.write_text(json.dumps({"unrelated": {"keep": True}}))
        self.patch("ui", {"thinking": True})
        self.change({"preferences": {"pinned": True, "archived": True}})
        for _ in range(3):
            self.app.api(
                f"/sessions/{self.session}/visits/{operation_id()}", {}, method="PUT"
            ).close()
        self.app.restart()
        self.assertEqual(json.loads(picker.read_text())["unrelated"], {"keep": True})
        session = self.read(f"/sessions/{self.session}")
        self.assertTrue(self.group("ui")["thinking"])
        self.assertEqual(
            (
                session["preferences"]["pinned"],
                session["preferences"]["archived"],
                session["preferences"]["opens"],
            ),
            (True, True, 3),
        )
        resource = session["configuration_resource"]
        self.app.api(
            resource["url"], method="DELETE", headers={"If-Match": resource["etag"]}
        ).close()
        self.assertNotIn(
            self.session,
            [item["id"] for item in self.read("/sessions?archived=true")["items"]],
        )
        stored = json.loads(picker.read_text())
        self.assertNotIn(self.session, json.dumps(stored))

    # exclusive: global choices and explicit session overrides remain separate
    @exclusive
    # exclusive: changes daemon-wide extension and capability defaults
    @exclusive
    def test_capability_defaults_and_overrides_control_context_and_loaded_commands(
        self,
    ):
        extension_file = self.app.home / "extensions.json"
        before_bytes = extension_file.read_bytes()
        with self.app.api("/settings?group=extensions") as response:
            before_settings = json.load(response)
            before_etag = response.headers["ETag"]
        with self.assertRaises(urllib.error.HTTPError) as conflict:
            self.patch("extensions", {"defaults": {"lcm": True, "rolling": True}})
        self.assertEqual(conflict.exception.code, 400)
        self.assertEqual(json.load(conflict.exception)["code"], "selection_conflict")
        self.assertEqual(extension_file.read_bytes(), before_bytes)
        with self.app.api("/settings?group=extensions") as response:
            self.assertEqual(json.load(response), before_settings)
            self.assertEqual(response.headers["ETag"], before_etag)
        for selected, displaced in [("lcm", "rolling"), ("rolling", "lcm")]:
            self.patch("extensions", {"defaults": {selected: True}})
            session = self.app.session()
            effective = self.read(f"/sessions/{session}?tail=0")["selection"][
                "effective"
            ]["extensions"]
            self.assertTrue(effective[selected])
            self.assertFalse(effective[displaced])
        (self.app.workspace / "AGENTS.md").write_text("CAPABILITY_INSTRUCTION_MARKER")
        self.write_skill("preference-demo", "CAPABILITY_SKILL_MARKER")
        self.assertIn("CAPABILITY_INSTRUCTION_MARKER", self.turn())
        self.assertIn("CAPABILITY_SKILL_MARKER", self.turn())
        self.choice("project:AGENTS.md", global_default=True)
        self.choice("preference-demo", kind="skills", global_default=True)
        disabled = self.app.session()
        context = self.turn(session=disabled)
        self.assertNotIn("CAPABILITY_INSTRUCTION_MARKER", context)
        self.assertNotIn("CAPABILITY_SKILL_MARKER", context)
        self.choice("project:AGENTS.md", enabled=True)
        self.choice("preference-demo", kind="skills", enabled=True)
        self.reload()
        context = self.turn()
        self.assertIn("CAPABILITY_INSTRUCTION_MARKER", context)
        self.assertIn("CAPABILITY_SKILL_MARKER", context)
        self.assertIn(
            "/preference-demo", {row["slash_name"] for row in self.commands()}
        )
        self.choice("preference-demo", kind="skills", enabled=None)
        self.reload()
        self.assertNotIn(
            "/preference-demo", {row["slash_name"] for row in self.commands()}
        )
        self.assertNotIn("CAPABILITY_SKILL_MARKER", self.turn(session=disabled))

    # exclusive: changes daemon-wide extension defaults
    @exclusive
    def test_saves_report_composition_changes_and_reload_lists_are_asked_for(self):
        # More loaded sessions than one observation window, so the list
        # gathers several windows.
        sessions = [self.session] + [self.app.session() for _ in range(3)]
        for session in sessions:
            self.turn(session=session)

        def pending():
            return {
                row["id"]
                for row in self.read("/sessions?scope=all&needs_reload=true")["items"]
            }

        # A group that never feeds composition reports no change.
        ui = self.patch("ui", {"thinking": False})
        self.assertFalse(ui["application"]["composition_changed"])
        self.assertNotIn("needs_reload_count", ui["application"])
        self.assertEqual(pending(), set())

        # A default every session inherits changes the desired composition,
        # and the sessions behind it are listed when asked for.
        extensions = self.patch("extensions", {"defaults": {"view": True}})
        self.assertTrue(extensions["application"]["composition_changed"])
        self.assertEqual(pending(), set(sessions))

        # A reload brings one session up to date; the rest stay listed.
        self.reload(session=sessions[0])
        self.assertEqual(pending(), set(sessions[1:]))

    # exclusive: malformed preferences cannot be hidden by a session override
    @exclusive
    def test_failed_reload_keeps_loaded_commands_and_does_not_overwrite_malformed_preferences(
        self,
    ):
        skill = self.write_skill("validated-choice", "PREPARED_CHOICE")
        self.choice("validated-choice", kind="skills", enabled=True)
        self.reload()
        prepared = self.commands()
        path = self.app.home / "capabilities.json"
        preferences = json.loads(path.read_text()) if path.exists() else {}
        preferences["global"] = {"skills": {"validated-choice": "invalid"}}
        path.write_text(json.dumps(preferences))
        malformed = path.read_bytes()
        skill.write_text(
            skill.read_text().replace("PREPARED_CHOICE", "REPAIRED_CHOICE")
        )
        outcome = self.reload()
        self.assertEqual(outcome["session"]["state"], "failed")
        self.assertEqual(path.read_bytes(), malformed)
        self.assertEqual(self.commands(), prepared)
        preferences["global"]["skills"]["validated-choice"] = False
        path.write_text(json.dumps(preferences))
        self.assertEqual(self.reload()["session"]["state"], "applied")
        self.assertEqual(
            next(
                row["description"]
                for row in self.commands()
                if row["slash_name"] == "/validated-choice"
            ),
            "REPAIRED_CHOICE",
        )

    # exclusive: disabled invalid instructions must not enter model context
    @exclusive
    def test_disabled_instruction_is_not_read_until_enabled(self):
        (self.app.workspace / "AGENTS.md").write_bytes(b"\xff")
        (self.app.workspace / "CLAUDE.md").write_text("READABLE_INSTRUCTION")
        self.choice("project:AGENTS.md", global_default=True)
        before = self.group("capabilities")
        invalid = next(
            row
            for row in self.discovery()["candidates"]
            if row["preference_key"] == "project:AGENTS.md"
        )
        self.assertFalse(invalid["valid"])
        self.assertTrue(invalid["diagnostic"])
        self.assertFalse(invalid["eligible"])
        self.assertIn("READABLE_INSTRUCTION", self.turn())
        with self.assertRaises(urllib.error.HTTPError):
            self.choice("project:AGENTS.md", enabled=True)
        self.assertEqual(self.group("capabilities"), before)

    # exclusive: checks the persisted capability document byte boundary
    @exclusive
    def test_capability_size_limit_accepts_boundary_and_rejects_growth(self):
        (self.app.workspace / "AGENTS.md").write_text("bounded preference")
        self.write_skill("new-choice", "size boundary")
        path = self.app.home / "capabilities.json"
        limit = 1048576
        for size in (limit - 1, limit):
            document = {
                "padding": "",
                "global": {"instructions": {"project:AGENTS.md": False}},
            }
            overhead = len(json.dumps(document, separators=(",", ":")).encode())
            document["padding"] = "a" * (size - overhead)
            content = json.dumps(document, separators=(",", ":")).encode()
            self.assertEqual(len(content), size)
            path.write_bytes(content)
            self.group("capabilities")
            try:
                self.choice("project:AGENTS.md", global_default=True)
            except urllib.error.HTTPError as error:
                error.add_note(
                    f"capability boundary submitted {size} bytes; persisted {path.stat().st_size} bytes"
                )
                raise
            self.assertEqual(path.stat().st_size, size)
            with self.assertRaises(urllib.error.HTTPError):
                self.choice("new-choice", kind="skills", global_default=True)
            self.assertEqual(json.loads(path.read_bytes()), document)
        content += b" "
        path.write_bytes(content)
        with self.assertRaises(urllib.error.HTTPError):
            self.group("capabilities")
        catalog = self.read(f"/sessions/{self.session}/catalog")
        self.assertIsNone(catalog["discovery"])
        self.assertIsNotNone(catalog["discovery_failure"])
        self.assertEqual(path.read_bytes(), content)

    # exclusive: validates global MCP candidates before saving secrets
    @exclusive
    def test_mcp_failed_candidate_keeps_configuration_credentials_and_loaded_tools(
        self,
    ):
        self.change({"selection": {"extensions": {"mcp": True}}})
        server = {
            "enabled": True,
            "transport": "stdio",
            "command": sys.executable,
            "arguments": [str(SERVER)],
            "secrets": {"environment": {"FAKE_SECRET": "settings-mcp-secret"}},
        }
        self.patch("mcp", {"definitions": {"settings-mcp": server}})
        self.reload()
        before = self.group("mcp")
        self.assertNotIn("settings-mcp-secret", json.dumps(before))
        self.assertEqual(
            before["definitions"]["settings-mcp"]["secret_presence"]["environment"],
            ["FAKE_SECRET"],
        )
        creds = (self.app.home / "creds.json").read_bytes()
        with self.assertRaises(urllib.error.HTTPError):
            self.patch(
                "mcp",
                {
                    "definitions": {
                        "settings-mcp": {
                            "command": "/missing/mcp",
                            "secrets": {
                                "environment": {"FAKE_SECRET": "changed-secret"}
                            },
                        }
                    }
                },
            )
        self.assertEqual(self.group("mcp"), before)
        self.assertEqual((self.app.home / "creds.json").read_bytes(), creds)
        self.turn("still usable")
        tools = self.provider.requests[-1]["request"]["tools"]
        self.assertTrue(
            any(
                tool.get("name", tool.get("function", {}).get("name", "")).startswith(
                    "mcp_settings_mcp_"
                )
                for tool in tools
            )
        )
        self.patch("mcp", {"definitions": {"settings-mcp": None}})
        self.assertNotIn("settings-mcp", self.group("mcp")["definitions"])
        self.assertNotIn(
            "settings-mcp",
            json.loads((self.app.home / "creds.json").read_text())["mcp"],
        )

    # exclusive: malformed persistent documents must never be overwritten
    @exclusive
    def test_malformed_documents_reject_saves_without_overwriting(self):
        cases = [
            ("picker.json", "ui", {"tools": True}, {"tools": "yes"}),
            (
                "config.json",
                "providers",
                {"profiles": {"sample": self.profile()}},
                {"providers": []},
            ),
            (
                "extensions.json",
                "mcp",
                {
                    "definitions": {
                        "sample": {
                            "enabled": False,
                            "transport": "http",
                            "url": "http://localhost/mcp",
                        }
                    }
                },
                {"mcp": {"servers": []}},
            ),
        ]
        for name, group, fields, malformed in cases:
            path = self.app.home / name
            prior = path.read_bytes() if path.exists() else None
            try:
                for content in (b'{"broken":', json.dumps(malformed).encode()):
                    path.write_bytes(content)
                    with self.assertRaises(urllib.error.HTTPError):
                        self.patch(group, fields)
                    self.assertEqual(path.read_bytes(), content)
            finally:
                if prior is None:
                    path.unlink(missing_ok=True)
                else:
                    path.write_bytes(prior)
        for group, fields in (
            ("ui", {"tools": "yes"}),
            ("providers", {"profiles": {"sample": self.profile(protocol="wrong")}}),
            (
                "mcp",
                {
                    "definitions": {
                        "sample": {
                            "enabled": False,
                            "transport": "http",
                            "url": "file:///tmp/server",
                        }
                    }
                },
            ),
        ):
            with self.assertRaises(urllib.error.HTTPError):
                self.patch(group, fields)

    # exclusive: persistence must fail atomically when the directory cannot be written
    @exclusive
    def test_failed_persistence_keeps_old_settings_and_credentials(self):
        paths = [self.app.home / name for name in ("config.json", "creds.json")]
        before = [path.read_bytes() if path.exists() else None for path in paths]
        mode = stat.S_IMODE(self.app.home.stat().st_mode)
        try:
            self.app.home.chmod(0o500)
            with self.assertRaises(urllib.error.HTTPError):
                self.patch(
                    "providers",
                    {"profiles": {"failing": self.profile(api_key="must-not-save")}},
                )
        finally:
            self.app.home.chmod(mode)
        self.assertEqual(
            [path.read_bytes() if path.exists() else None for path in paths], before
        )

    # exclusive: MCP validation and another settings save must not deadlock
    @exclusive
    def test_slow_mcp_validation_and_independent_ui_save_complete_when_overlapping(
        self,
    ):
        marker = self.app.workspace / "mcp-started"
        gate = self.app.workspace / "mcp-release"
        os.mkfifo(gate)
        script = (
            "import pathlib; "
            + f"pathlib.Path({str(marker)!r}).touch(); "
            + f"open({str(gate)!r}, 'rb').read(1) if pathlib.Path({str(gate)!r}).exists() else None; "
            + f"exec(pathlib.Path({str(SERVER)!r}).read_text())"
        )
        candidate = {
            "definitions": {
                "slow-start": {
                    "enabled": True,
                    "transport": "stdio",
                    "command": sys.executable,
                    "arguments": ["-c", script],
                    "startup_timeout_ms": 30000,
                }
            }
        }
        with ThreadPoolExecutor(max_workers=2) as pool:
            mcp = pool.submit(self.patch, "mcp", candidate)
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "MCP validation did not start")
            try:
                original = pool.submit(self.group, "mcp").result(timeout=10)
                pool.submit(self.group, "ui").result(timeout=10)
                pool.submit(self.patch, "ui", {"tools": True}).result(timeout=10)
                newer = {
                    "definitions": {
                        "newer": {
                            "enabled": False,
                            "transport": "stdio",
                            "command": sys.executable,
                        }
                    }
                }
                pool.submit(self.patch, "mcp", newer).result(timeout=10)
                paths = [self.app.home / name for name in ("config.json", "creds.json")]
                committed = [
                    path.read_bytes() if path.exists() else None for path in paths
                ]
            finally:
                deadline = time.monotonic() + 10
                while True:
                    try:
                        descriptor = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                        break
                    except OSError as error:
                        if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                            raise
                        time.sleep(0.01)
                try:
                    os.write(descriptor, b"x")
                finally:
                    os.close(descriptor)
                    gate.unlink()
            with self.assertRaises(urllib.error.HTTPError) as conflict:
                mcp.result(timeout=40)
            self.assertEqual(conflict.exception.code, 412)
            self.assertEqual(
                [path.read_bytes() if path.exists() else None for path in paths],
                committed,
            )
        current = self.group("mcp")
        self.assertNotIn("slow-start", current["definitions"])
        self.assertIn("newer", current["definitions"])
        self.assertNotEqual(current, original)
        self.assertTrue(self.group("ui")["tools"])
        self.patch("mcp", candidate)
        self.assertIn("slow-start", self.group("mcp")["definitions"])

    def test_settings_routes_reject_missing_authentication_and_browser_origins(self):
        for method, path in (
            ("GET", "/settings"),
            ("PATCH", "/settings?group=providers"),
            ("PATCH", "/settings?group=ui"),
            ("PATCH", f"/sessions/{self.session}?view=configuration"),
            ("PUT", f"/sessions/{self.session}/visits/{operation_id()}"),
        ):
            for headers in (
                {},
                {"Origin": "http://localhost"},
                {
                    "Authorization": "Bearer " + self.app.connection["token"],
                    "Origin": "http://localhost",
                },
            ):
                request = urllib.request.Request(
                    self.app.base + path, method=method, headers=headers
                )
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    urllib.request.urlopen(request, timeout=10)
                self.assertEqual(
                    caught.exception.code, 403 if "Origin" in headers else 401
                )
                if "Origin" not in headers:
                    self.assertEqual(
                        caught.exception.headers["WWW-Authenticate"], "Bearer"
                    )

    def test_busy_session_rejects_settings_before_persistence(self):
        entered, release = threading.Event(), threading.Event()

        def script(_request):
            entered.set()
            release.wait(10)
            return text("finished")

        self.provider.script = script
        self.addCleanup(release.set)
        self.app.prompt(self.session, "wait").close()
        self.assertTrue(entered.wait(10))
        route = f"/sessions/{self.session}?view=configuration"
        before = self.read(route)
        try:
            with self.assertRaises(urllib.error.HTTPError) as caught:
                self.change({"selection": {"extensions": {"mcp": True}}})
            self.assertEqual(caught.exception.code, 409)
            self.assertEqual(self.read(route), before)
        finally:
            release.set()
            self.app.idle(self.session)


if __name__ == "__main__":
    unittest.main()
