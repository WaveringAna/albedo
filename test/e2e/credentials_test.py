"""Every secret lives in creds.json, and only the daemon reads or writes it.

A boot moves secrets still kept in auth.json, mcp-credentials.json or a
config.json profile into creds.json; clients then change them through the
daemon, which never answers with a secret. Both are only visible through a
real daemon: the move happens at boot, and the keys prove themselves in the
requests the provider receives.
"""

import json
import stat
import unittest

from harness import Albedo, Provider, exclusive, text


class CredentialsTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)

    def app_for(self, prepare=None):
        app = Albedo(self.provider, prepare=prepare)
        app.__enter__()
        self.addCleanup(app.__exit__, None, None, None)
        return app

    def authorization(self, app):
        """The Authorization header of a turn on the active profile."""
        start = len(self.provider.requests)
        session = app.session()
        app.prompt(session, "which key").close()
        app.idle(session)
        return self.provider.requests[start:][-1]["authorization"]

    def summary(self, app):
        with app.api("/settings") as response:
            return response.read().decode()

    # exclusive: restarts the daemon to migrate global credential files
    @exclusive
    def test_a_boot_moves_every_secret_into_creds_json(self):
        app = self.app_for()
        # Written while the daemon runs, so the restart below is what moves them.
        for name, content in {
            "auth.json": {"anthropic": [{"type": "oauth", "access": "old-access"}]},
            "mcp-credentials.json": {"servers": {"docs": {"bearerToken": "old-token"}}},
        }.items():
            (app.home / name).write_text(json.dumps(content))
            (app.home / name).chmod(0o600)
        config = json.loads((app.home / "config.json").read_text())
        config["providers"][app.profile]["apiKey"] = "fixture-key"
        (app.home / "config.json").write_text(json.dumps(config))
        app.restart()
        creds = json.loads((app.home / "creds.json").read_text())
        self.assertEqual(creds["accounts"]["anthropic"][0]["access"], "old-access")
        self.assertEqual(creds["mcp"]["docs"], {"bearerToken": "old-token"})
        self.assertEqual(creds["providers"][app.profile], {"apiKey": "fixture-key"})
        self.assertEqual(stat.S_IMODE((app.home / "creds.json").stat().st_mode), 0o600)
        config = json.loads((app.home / "config.json").read_text())
        self.assertNotIn("apiKey", config["providers"][app.profile])
        self.assertFalse((app.home / "auth.json").exists())
        self.assertFalse((app.home / "mcp-credentials.json").exists())
        backups = {path.name.split("-before-creds-")[0] for path in self.backups(app)}
        self.assertEqual(backups, {"auth.json", "mcp-credentials.json", "config.json"})
        with app.api("/server") as response:
            notices = json.load(response)["notices"]
        migrated = " ".join(
            notice["message"] for notice in notices if notice["kind"] == "migration"
        )
        for name in ("auth.json", "mcp-credentials.json", "config.json"):
            self.assertIn(name, migrated)
        self.assertNotIn("old-access", migrated)
        self.assertNotIn("old-token", migrated)
        # Not even their owner reads them without a chmod first.
        self.assertEqual(
            {stat.S_IMODE(path.stat().st_mode) for path in self.backups(app)}, {0}
        )
        # The moved key still reaches the provider.
        self.assertEqual(self.authorization(app), "Bearer fixture-key")

    @exclusive
    def test_clients_change_secrets_without_reading_them(self):
        # No legacy config key: clients store and rotate only this fixture's
        # credential, without depending on startup migration of config.json.
        app = Albedo(
            self.provider,
            providers={
                f"fixture-{self.provider.route}": {
                    "baseUrl": self.provider.url,
                    "model": "fixture-model",
                    "protocol": "chat_completions",
                }
            },
        )
        app.__enter__()
        self.addCleanup(app.__exit__, None, None, None)
        server = app.profile

        def patch(group, body):
            route = f"/settings?group={group}"
            with app.api(route) as response:
                json.load(response)
                revision = response.headers["ETag"]
            with app.api(
                route,
                body,
                method="PATCH",
                headers={
                    "If-Match": revision,
                    "Content-Type": "application/merge-patch+json",
                },
            ) as response:
                return json.load(response)["resource"]["value"]

        patch("providers", {"profiles": {app.profile: {"api_key": "fixture-key"}}})
        self.assertEqual(self.authorization(app), "Bearer fixture-key")
        patch("providers", {"profiles": {app.profile: {"api_key": "rotated-key"}}})
        self.assertEqual(self.authorization(app), "Bearer rotated-key")
        value = patch(
            "mcp",
            {
                "definitions": {
                    server: {
                        "enabled": False,
                        "transport": "http",
                        "url": "http://127.0.0.1:1/mcp",
                        "secrets": {
                            "bearer_token": "secret-token",
                            "headers": {"X-Team": "secret-team"},
                        },
                    }
                }
            },
        )
        self.assertEqual(
            value["definitions"][server]["secret_presence"],
            {"bearer_token": True, "headers": ["X-Team"], "environment": []},
        )
        value = patch(
            "mcp",
            {
                "definitions": {
                    server: {
                        "secrets": {
                            "bearer_token": None,
                            "environment": {"TOKEN": "secret-env"},
                        }
                    }
                }
            },
        )
        self.assertEqual(
            value["definitions"][server]["secret_presence"],
            {"bearer_token": False, "headers": ["X-Team"], "environment": ["TOKEN"]},
        )
        summary = self.summary(app)
        self.assertFalse(
            any(
                secret in summary
                for secret in (
                    "rotated-key",
                    "secret-token",
                    "secret-team",
                    "secret-env",
                    "fixture-key",
                )
            )
        )
        patch("mcp", {"definitions": {server: None}})
        with (app.home / "creds.json").open() as source:
            self.assertNotIn(server, json.load(source).get("mcp", {}))

    def backups(self, app):
        return list((app.home / "backups").glob("*-before-creds-*"))
