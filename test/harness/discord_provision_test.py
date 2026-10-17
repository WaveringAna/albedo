"""The provisioning script against a fake Discord user API, over its real stdin/stdout protocol.

The daemon end-to-end suite only sees what the provisioner reports once the
whole feature is wired up. This drives albedo_discord_provision.py alone and
catches what it cannot: an intent flag that overwrites the application's other
flag bits, an MFA retry that forgets X-Discord-MFA-Authorization (or loops
forever on a wrong code), a closed stdin that leaves the process hanging, a
captcha reported as a generic failure so the UI cannot fall back to the
portal, guilds offered where the user cannot add bots, and a user or bot token
leaking anywhere but the final create result.
"""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test" / "e2e"))
from discord_fake_support import FakeDiscord  # noqa: E402

SCRIPT = ROOT / "priv" / "python" / "albedo_discord_provision.py"
BOT = ROOT / "priv" / "python" / "albedo_discord.py"
INTENT = 1 << 19
MANAGE_GUILD = 1 << 5
ADMINISTRATOR = 1 << 3
CODE = "123456"


class Provisioner:
    def __init__(self, fake: FakeDiscord, user_token: str | None = None) -> None:
        env = dict(os.environ)
        env["ALBEDO_DISCORD_USER_TOKEN"] = user_token or fake.user_token
        env["ALBEDO_DISCORD_API"] = fake.api_url
        self.proc = subprocess.Popen(
            [sys.executable, str(SCRIPT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            text=True,
        )
        self.lines: queue.Queue[str] = queue.Queue()
        self.stdout: list[str] = []
        self.stderr = ""
        threading.Thread(target=self._pump, daemon=True).start()
        self.errors = threading.Thread(target=self._drain, daemon=True)
        self.errors.start()

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.stdout.append(line)
            self.lines.put(line)

    def _drain(self) -> None:
        assert self.proc.stderr is not None
        self.stderr = self.proc.stderr.read()

    def send(self, line: dict) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(line) + "\n")
        self.proc.stdin.flush()

    def read(self, timeout: float = 15) -> dict:
        try:
            return json.loads(self.lines.get(timeout=timeout))
        except queue.Empty:
            raise TimeoutError(f"no output; saw {self.stdout}") from None

    def until(self, kind: str) -> tuple[list[dict], dict]:
        """(earlier lines, the first line of this type)."""
        before = []
        while True:
            line = self.read()
            if line["type"] == kind:
                return before, line
            before.append(line)

    def result(self) -> dict:
        _, line = self.until("result")
        return line

    def finish(self) -> int:
        self.errors.join(10)
        return self.proc.wait(15)

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(10)
        for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
            if stream:
                stream.close()


class DiscordProvisionTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeDiscord()
        self.addCleanup(self.fake.stop)

    def run_op(self, request: dict, user_token: str | None = None) -> Provisioner:
        proc = Provisioner(self.fake, user_token)
        self.addCleanup(proc.close)
        proc.send(request)
        return proc

    def create(self, name: str = "albedo") -> Provisioner:
        return self.run_op({"op": "create", "name": name, "avatar": None})

    def assert_failure(self, proc: Provisioner, code: str) -> dict:
        result = proc.result()
        self.assertEqual((result["ok"], result["code"]), (False, code), result)
        self.assertEqual(proc.finish(), 1)
        return result

    def assert_no_leak(self, proc: Provisioner, allowed: str) -> None:
        proc.finish()
        text = "".join(proc.stdout) + proc.stderr
        self.assertNotIn(self.fake.user_token, text)
        for token in self.fake.token_users:
            if token != allowed:
                self.assertNotIn(token, text)

    def test_create_walks_the_steps_and_returns_a_working_bot_token(self):
        proc = self.create("my bot")
        steps, result = proc.until("result")
        self.assertEqual(
            [s["step"] for s in steps if s["type"] == "progress"],
            ["create", "bot", "intent", "token"],
        )
        self.assertTrue(result["ok"])
        made = result["result"]
        app = self.fake.applications[made["application_id"]]
        self.assertEqual(made["name"], "my bot")
        self.assertEqual(made["bot_user_id"], app["bot"]["id"])
        self.assertEqual(made["username"], "my bot")
        self.assertEqual(proc.finish(), 0)
        # the token is the only secret printed, and only in the result line
        self.assertEqual(proc.stderr, "")
        self.assertEqual(
            [line for line in proc.stdout if made["token"] in line],
            [json.dumps(result) + "\n"],
        )
        self.assert_no_leak(proc, allowed=made["token"])
        for call in self.fake.user_calls:
            self.assertIsNone(call["mfa"])
        # the gateway accepts the new token and logs in as the new bot
        env = dict(os.environ)
        env["ALBEDO_DISCORD_TOKEN"] = made["token"]
        env["ALBEDO_DISCORD_API"] = self.fake.api_url
        bot = subprocess.Popen(
            [sys.executable, str(BOT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            text=True,
        )
        self.addCleanup(bot.wait)
        self.addCleanup(bot.kill)
        assert bot.stdout is not None
        user = None
        for line in bot.stdout:
            status = json.loads(line)
            if status["type"] == "status" and status["state"] == "online":
                user = status["user"]
                break
        assert user is not None
        self.assertEqual(user["id"], made["bot_user_id"])

    def test_create_with_avatar_sets_it_on_the_bot(self):
        avatar = "data:image/png;base64,AAAA"
        proc = self.run_op({"op": "create", "name": "pic", "avatar": avatar})
        made = proc.result()["result"]
        bot = self.fake.applications[made["application_id"]]["bot"]
        self.assertEqual(bot["avatar"], avatar)

    def test_flags_keep_existing_bits_and_add_message_content(self):
        existing = (1 << 12) | (1 << 23) | 1
        self.fake.new_app_flags = existing
        made = self.create().result()["result"]
        flags = self.fake.applications[made["application_id"]]["flags"]
        self.assertEqual(flags, existing | INTENT)

    def test_bot_user_is_created_once(self):
        self.create().result()
        botified = [
            c
            for c in self.fake.user_calls
            if (c["method"], c["path"].endswith("/bot")) == ("POST", True)
        ]
        self.assertEqual(len(botified), 1)

    def test_mfa_prompts_then_retries_with_the_mfa_token(self):
        self.fake.require_mfa(CODE)
        proc = self.create()
        before, prompt = proc.until("mfa")
        self.assertEqual(prompt["methods"], ["totp"])
        self.assertNotIn("error", prompt)
        proc.send({"code": CODE})
        result = proc.result()
        self.assertTrue(result["ok"], result)
        self.assertEqual(proc.finish(), 0)
        self.assertEqual(self.fake.mfa_attempts[0]["mfa_type"], "totp")
        self.assertEqual(self.fake.mfa_attempts[0]["data"], CODE)
        resets = [c for c in self.fake.user_calls if c["path"].endswith("/bot/reset")]
        self.assertEqual(len(resets), 2)
        self.assertIsNone(resets[0]["mfa"])
        self.assertTrue(resets[1]["mfa"].startswith("mfa-token"))
        self.assertEqual(
            [s["step"] for s in before if s["type"] == "progress"],
            ["create", "bot", "intent", "token"],
        )

    def test_wrong_code_asks_again_then_accepts_the_right_one(self):
        self.fake.require_mfa(CODE)
        proc = self.create()
        proc.until("mfa")
        proc.send({"code": "000000"})
        _, again = proc.until("mfa")
        self.assertIn("Invalid", again["error"])
        proc.send({"code": CODE})
        self.assertTrue(proc.result()["ok"])
        self.assertEqual(len(self.fake.mfa_attempts), 2)

    def test_three_wrong_codes_fail_with_mfa_failed(self):
        self.fake.require_mfa(CODE)
        proc = self.create()
        for _ in range(3):
            proc.until("mfa")
            proc.send({"code": "000000"})
        self.assert_failure(proc, "mfa_failed")
        self.assertEqual(len(self.fake.mfa_attempts), 3)
        self.assertEqual(len(self.fake.applications), 1)  # created, never reset

    def test_stdin_eof_during_mfa_exits(self):
        self.fake.require_mfa(CODE)
        proc = self.create()
        proc.until("mfa")
        assert proc.proc.stdin is not None
        proc.proc.stdin.close()
        self.assert_failure(proc, "mfa_failed")

    def test_unsupported_mfa_methods_fail_without_prompting(self):
        self.fake.require_mfa(CODE, methods=[{"type": "webauthn", "challenge": "{}"}])
        proc = self.create()
        result = self.assert_failure(proc, "mfa_failed")
        self.assertIn("authenticator", result["error"])

    def test_captcha_is_reported_with_its_code(self):
        self.fake.require_captcha("POST", "/applications")
        result = self.assert_failure(self.create(), "captcha")
        self.assertIn("captcha", result["error"])

    def test_invalid_form_body_reports_discords_field_errors(self):
        # Discord answers 50035 with the reason only inside `errors`.
        result = self.assert_failure(self.create("DiscordTester"), "http")
        self.assertEqual(
            result["error"], 'HTTP 400: Application name cannot contain "discord"'
        )

    def test_rejected_user_token_is_unauthorized(self):
        proc = self.run_op({"op": "apps"}, user_token="wrong.token.value")
        self.assert_failure(proc, "unauthorized")
        self.fake.revoke_user_token()
        self.assert_failure(self.run_op({"op": "apps"}), "unauthorized")

    def test_rate_limit_is_retried_once_then_reported(self):
        self.fake.throttle(1, retry_after=0.1)
        self.assertTrue(self.run_op({"op": "apps"}).result()["ok"])
        self.fake.throttle(10, retry_after=60)
        self.assert_failure(self.run_op({"op": "apps"}), "rate_limited")

    def test_bad_requests_are_http_failures(self):
        proc = Provisioner(self.fake)
        self.addCleanup(proc.close)
        proc.send({"op": "nope"})
        self.assert_failure(proc, "http")
        self.assert_failure(self.run_op({"op": "create", "name": " "}), "http")

    def test_me_names_the_account_without_echoing_the_token(self):
        proc = self.run_op({"op": "me"})
        result = proc.result()
        self.assertEqual(
            result["result"],
            {"id": "100000000000000090", "username": "owner", "global_name": "Owner"},
        )
        self.assert_no_leak(proc, allowed="")

    def test_me_with_a_revoked_token_is_unauthorized(self):
        self.fake.revoke_user_token()
        self.assert_failure(self.run_op({"op": "me"}), "unauthorized")

    def test_guilds_are_filtered_by_permissions(self):
        self.fake.add_user_guild("1", "plain", permissions=1 << 10)
        self.fake.add_user_guild("2", "manager", permissions=MANAGE_GUILD, icon="ic")
        self.fake.add_user_guild("3", "admin", permissions=ADMINISTRATOR | 1)
        self.fake.add_user_guild("4", "owned", permissions=0, owner=True)
        result = self.run_op({"op": "guilds"}).result()
        self.assertEqual(
            result["result"],
            [
                {"id": "2", "name": "manager", "icon": "ic"},
                {"id": "3", "name": "admin", "icon": None},
                {"id": "4", "name": "owned", "icon": None},
            ],
        )

    def test_authorize_posts_the_invite(self):
        app = self.fake.add_application("inviteme")
        proc = self.run_op(
            {"op": "authorize", "application_id": app, "guild_id": "200"}
        )
        result = proc.result()
        self.assertEqual((result["ok"], result["result"]), (True, None))
        sent = self.fake.authorized[0]
        self.assertEqual(sent["query"]["client_id"], app)
        self.assertEqual(sent["query"]["scope"], "bot")
        self.assertEqual(sent["query"]["permissions"], "274878024768")
        self.assertEqual(
            sent["body"],
            {"guild_id": "200", "permissions": "274878024768", "authorize": True},
        )

    def test_authorize_handles_mfa_and_captcha(self):
        app = self.fake.add_application("inviteme")
        self.fake.require_mfa(CODE)
        proc = self.run_op({"op": "authorize", "application_id": app, "guild_id": "2"})
        proc.until("mfa")
        proc.send({"code": CODE})
        self.assertTrue(proc.result()["ok"])
        self.assertTrue(self.fake.user_calls[-1]["mfa"])
        self.fake.require_captcha("POST", "/oauth2/authorize")
        again = self.run_op({"op": "authorize", "application_id": app, "guild_id": "2"})
        self.assertEqual(again.result()["code"], "captcha")

    def test_apps_lists_only_applications_with_bots(self):
        with_bot = self.fake.add_application("has bot")
        self.fake.add_application("no bot", bot=False)
        result = self.run_op({"op": "apps"}).result()["result"]
        self.assertEqual(
            result,
            [
                {
                    "id": with_bot,
                    "name": "has bot",
                    "bot_user_id": self.fake.applications[with_bot]["bot"]["id"],
                }
            ],
        )

    def test_delete_removes_the_application_behind_mfa(self):
        app = self.fake.add_application("doomed")
        self.fake.require_mfa(CODE)
        proc = self.run_op({"op": "delete", "application_id": app})
        proc.until("mfa")
        proc.send({"code": CODE})
        result = proc.result()
        self.assertEqual((result["ok"], result["result"]), (True, None))
        self.assertNotIn(app, self.fake.applications)


if __name__ == "__main__":
    unittest.main()
