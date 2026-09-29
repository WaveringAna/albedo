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
        with app.api("/auth/credentials") as response:
            return response.read().decode()

    @exclusive
    def test_a_boot_moves_every_secret_into_creds_json(self):
        app = self.app_for()
        self.addCleanup(self.forget_backups, app)
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
        # The first client to ask hears about the move; later ones do not.
        for expected in (["auth.json", "mcp-credentials.json", "config.json"], []):
            with app.api("/auth/credentials/migration", {}) as response:
                self.assertEqual(json.load(response)["moved"], expected)
        # Not even their owner reads them without a chmod first.
        self.assertEqual(
            {stat.S_IMODE(path.stat().st_mode) for path in self.backups(app)}, {0}
        )
        # The moved key still reaches the provider.
        self.assertEqual(self.authorization(app), "Bearer fixture-key")

    @exclusive
    def test_clients_change_secrets_without_reading_them(self):
        app = self.app_for()
        config = json.loads((app.home / "config.json").read_text())
        del config["providers"][app.profile]["apiKey"]
        (app.home / "config.json").write_text(json.dumps(config))
        app.api(
            f"/auth/credentials/providers/{app.profile}",
            {"apiKey": "rotated-key"},
            method="PUT",
        ).close()
        self.assertEqual(self.authorization(app), "Bearer rotated-key")

        def patch(body):
            with app.api(
                "/auth/credentials/mcp/docs", body, method="PATCH"
            ) as response:
                return json.load(response)["undo"]

        patch({"bearerToken": "secret-token", "headers": {"X-Team": "secret-team"}})
        undo = patch({"bearerToken": None, "env": {"TOKEN": "secret-env"}})
        summary = self.summary(app)
        self.assertIn(app.profile, json.loads(summary)["providers"])
        self.assertEqual(
            json.loads(summary)["mcp"]["docs"],
            {"bearerToken": False, "headers": ["X-Team"], "env": ["TOKEN"]},
        )
        app.api("/auth/credentials/mcp/docs/undo", {"token": undo}).close()
        self.assertEqual(
            json.loads(self.summary(app))["mcp"]["docs"],
            {"bearerToken": True, "headers": ["X-Team"], "env": []},
        )
        self.assertFalse(
            any(
                secret in summary
                for secret in ("rotated-key", "secret-", "fixture-key")
            )
        )

    def backups(self, app):
        return list((app.home / "backups").glob("*-before-creds-*"))

    def forget_backups(self, app):
        for path in self.backups(app):
            path.unlink()


if __name__ == "__main__":
    unittest.main()
