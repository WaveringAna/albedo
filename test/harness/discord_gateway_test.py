"""The Discord bot process against a fake Discord, over its real stdin/stdout protocol.

The daemon end-to-end suite only sees what the bot reports after a whole
session is wired up. This drives albedo_discord.py alone and catches what it
cannot: a reconnect that sends a fresh IDENTIFY instead of RESUME (replaying
or losing messages), a fatal close code that loops forever instead of
exiting, REST messages mislabelled as DMs because they carry no guild_id,
and replies lost or mixed up when several requests are in flight.
"""

import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test" / "e2e"))
from discord_fake_support import FakeDiscord  # noqa: E402

BOT = ROOT / "priv" / "python" / "albedo_discord.py"
ALICE = {"id": "100000000000000001", "username": "alice", "global_name": "Alice"}
OTHER_BOT = {"id": "100000000000000002", "username": "otherbot", "bot": True}


class BotProcess:
    def __init__(self, fake: FakeDiscord) -> None:
        env = dict(os.environ)
        env["ALBEDO_DISCORD_TOKEN"] = fake.token
        env["ALBEDO_DISCORD_API"] = fake.api_url
        self.proc = subprocess.Popen(
            [sys.executable, str(BOT)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            text=True,
        )
        self.lines: queue.Queue[dict] = queue.Queue()
        self.seen: list[dict] = []
        self.next_id = 0
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for line in self.proc.stdout:
            self.lines.put(json.loads(line))

    def take(self, match, timeout: float = 10) -> dict:
        """The first line (new or already seen) satisfying `match`."""
        for line in self.seen:
            if match(line):
                self.seen.remove(line)
                return line
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self.lines.get(timeout=max(0.01, deadline - time.monotonic()))
            except queue.Empty:
                raise TimeoutError(f"no matching line; saw {self.seen}") from None
            if match(line):
                return line
            self.seen.append(line)

    def online(self) -> dict:
        return self.take(lambda x: x["type"] == "status" and x["state"] == "online")

    def ask(self, op: str, **fields) -> dict:
        self.next_id += 1
        assert self.proc.stdin is not None
        request = {"id": self.next_id, "op": op, **fields}
        self.proc.stdin.write(json.dumps(request) + "\n")
        self.proc.stdin.flush()
        return self.take(lambda x: x["type"] == "reply" and x["id"] == self.next_id)

    def message(self, backfill: bool = False) -> dict:
        line = self.take(lambda x: x["type"] == "message" and x["backfill"] == backfill)
        return line["message"]

    def close(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.wait(10)


class DiscordGatewayTest(unittest.TestCase):
    def setUp(self) -> None:
        self.fake = FakeDiscord(heartbeat_interval_ms=200)
        self.addCleanup(self.fake.stop)
        self.fake.add_guild(
            "200",
            "Guild",
            channels=[
                {"id": "300", "name": "general", "position": 1},
                {"id": "301", "name": "Text", "type": 4, "position": 0},
            ],
            threads=[{"id": "310", "name": "a-thread", "parent_id": "300"}],
        )
        self.bot: BotProcess | None = None

    def start(self) -> BotProcess:
        self.bot = BotProcess(self.fake)
        self.addCleanup(self.bot.close)
        return self.bot

    def test_connects_and_reports_online_with_user_and_application(self):
        bot = self.start()
        status = bot.online()
        self.assertEqual(status["user"]["id"], self.fake.bot["id"])
        self.assertEqual(status["user"]["username"], "albedo-bot")
        self.assertEqual(status["application_id"], self.fake.application_id)
        self.assertEqual(self.fake.identifies[0]["intents"], 46593)
        self.fake.wait_for(lambda: self.fake.heartbeats > 0, 5, "a heartbeat")

    def test_guild_message_is_normalized_from_the_cache(self):
        bot = self.start()
        bot.online()
        self.fake.wait_for_gateway()
        bot.ask("guilds")  # GUILD_CREATE is cached before this reply
        first = self.fake.post("300", "earlier", author=ALICE, guild_id="200")
        bot.message()
        self.fake.post(
            "300",
            "hello <@bot>",
            author=OTHER_BOT,
            mentions=[self.fake.bot["id"], ALICE],
            reply_to=first,
            attachments=[
                {
                    "filename": "a.png",
                    "url": "http://x/a.png",
                    "content_type": "image/png",
                    "size": 3,
                }
            ],
            nick="Other",
        )
        message = bot.message()
        self.assertEqual(message["guild_id"], "200")
        self.assertEqual(message["guild_name"], "Guild")
        self.assertEqual(message["channel_name"], "general")
        self.assertIsNone(message["parent_id"])
        self.assertFalse(message["is_dm"])
        self.assertTrue(message["mentions_me"])
        self.assertEqual(message["reply_to"], first)
        self.assertEqual(message["nick"], "Other")
        self.assertTrue(message["author"]["bot"])
        self.assertEqual(
            [m["username"] for m in message["mentions"]], ["albedo-bot", "alice"]
        )
        self.assertEqual(message["attachments"][0]["filename"], "a.png")

    def test_thread_message_has_the_parent_channel(self):
        bot = self.start()
        bot.online()
        bot.ask("guilds")
        self.fake.post("310", "in thread", author=ALICE)
        message = bot.message()
        self.assertEqual(message["parent_id"], "300")
        self.assertEqual(message["channel_name"], "a-thread")
        self.assertFalse(message["mentions_me"])

    def test_dm_arrives_as_a_dm(self):
        bot = self.start()
        bot.online()
        self.fake.wait_for_gateway()
        channel = self.fake.dm_channel(ALICE["id"])
        self.fake.post(channel, "psst", author=ALICE)
        message = bot.message()
        self.assertTrue(message["is_dm"])
        self.assertIsNone(message["guild_id"])

    def test_send_splits_long_content_and_only_the_first_part_replies(self):
        bot = self.start()
        bot.online()
        text = "\n".join(["x" * 900] * 5) + "\n" + "y" * 2500
        reply = bot.ask("send", channel_id="300", content=text, reply_to="42")
        self.assertTrue(reply["ok"], reply)
        sent = self.fake.wait_for_sent(len(reply["result"]["ids"]))
        self.assertEqual(reply["result"]["channel_id"], "300")
        self.assertGreaterEqual(len(sent), 4)
        self.assertTrue(all(len(s["content"]) <= 2000 for s in sent))
        self.assertEqual("\n".join(s["content"] for s in sent[:3]).count("x"), 4500)
        self.assertEqual("".join(s["content"] for s in sent[-2:]).count("y"), 2500)
        self.assertEqual(sent[0]["message_reference"]["message_id"], "42")
        self.assertTrue(all(s["message_reference"] is None for s in sent[1:]))
        self.assertEqual(
            sent[0]["allowed_mentions"], {"parse": ["users"], "replied_user": True}
        )
        echoed = bot.message()  # the bot's own message comes back from the gateway
        self.assertTrue(echoed["author"]["bot"])

    def test_dm_opens_a_channel_then_sends(self):
        bot = self.start()
        bot.online()
        reply = bot.ask("dm", user_id=ALICE["id"], content="hi alice")
        self.assertTrue(reply["ok"], reply)
        channel = self.fake.dm_channel(ALICE["id"])
        self.assertEqual(reply["result"]["channel_id"], channel)
        self.assertEqual(self.fake.sent[0]["channel_id"], channel)
        self.assertEqual(self.fake.sent[0]["content"], "hi alice")

    def test_history_guilds_user_and_react(self):
        bot = self.start()
        bot.online()
        self.fake.wait_for_gateway()
        ids = [self.fake.post("300", f"m{i}", author=ALICE) for i in range(5)]
        bot.ask("guilds")
        history = bot.ask("history", channel_id="300", limit=3)["result"]
        self.assertEqual([m["content"] for m in history], ["m2", "m3", "m4"])
        self.assertFalse(history[0]["is_dm"])
        self.assertEqual(history[0]["channel_name"], "general")
        before = bot.ask("history", channel_id="300", limit=10, before=ids[2])["result"]
        self.assertEqual([m["content"] for m in before], ["m0", "m1"])

        guilds = bot.ask("guilds")["result"]
        self.assertEqual(guilds[0]["name"], "Guild")
        self.assertEqual(
            [c["name"] for c in guilds[0]["channels"]], ["Text", "general"]
        )
        self.assertEqual(guilds[0]["channels"][1]["type"], 0)

        user = bot.ask("user", user_id=ALICE["id"])["result"]
        self.assertEqual(user["username"], "alice")
        missing = bot.ask("user", user_id="1")
        self.assertFalse(missing["ok"])
        self.assertIn("HTTP 404", missing["error"])

        self.assertTrue(
            bot.ask("react", channel_id="300", message_id=ids[0], emoji="👍")["ok"]
        )
        self.assertEqual(self.fake.wait_for_reaction()[0]["emoji"], "👍")

    def test_catch_up_emits_backfill_messages_oldest_first(self):
        bot = self.start()
        bot.online()
        bot.ask("guilds")
        ids = [self.fake.post("300", f"m{i}", author=ALICE) for i in range(3)]
        for _ in ids:
            bot.message()
        reply = bot.ask("catch_up", channels=[{"channel_id": "300", "after": ids[0]}])
        self.assertEqual(reply["result"], {"messages": 2})
        got = [bot.message(backfill=True) for _ in range(2)]
        self.assertEqual([m["content"] for m in got], ["m1", "m2"])
        self.assertEqual(got[0]["channel_name"], "general")
        self.assertFalse(got[0]["is_dm"])

    def test_rate_limited_requests_are_retried(self):
        bot = self.start()
        bot.online()
        self.fake.throttle(2, retry_after=0.1)
        reply = bot.ask("user", user_id=self.fake.bot["id"])
        self.assertTrue(reply["ok"], reply)

    def test_forced_close_resumes_the_session_without_a_new_identify(self):
        bot = self.start()
        bot.online()
        self.fake.wait_for_gateway()
        self.fake.close_socket(4000)
        self.fake.post("300", "while away", author=ALICE)
        self.fake.wait_for_resumes(1, timeout=15)
        bot.online()
        self.assertEqual(len(self.fake.identifies), 1)
        self.assertEqual(bot.message()["content"], "while away")
        self.fake.drop_connection()
        self.fake.wait_for_resumes(2, timeout=15)
        bot.online()
        self.assertEqual(len(self.fake.identifies), 1)

    def test_reconnect_op_resumes(self):
        bot = self.start()
        bot.online()
        self.fake.wait_for_gateway()
        self.fake.send_op(7)
        self.fake.wait_for_resumes(1, timeout=15)
        bot.online()
        self.assertEqual(len(self.fake.identifies), 1)

    def test_rejected_token_is_fatal_and_exits_2(self):
        self.fake.reject_token()
        bot = self.start()
        fatal = bot.take(lambda x: x["type"] == "fatal")
        self.assertIn("token", fatal["detail"])
        self.assertEqual(bot.proc.wait(10), 2)

    def test_disallowed_intents_names_the_message_content_intent(self):
        self.fake.reject_intents()
        bot = self.start()
        fatal = bot.take(lambda x: x["type"] == "fatal")
        self.assertIn("Message Content", fatal["detail"])
        self.assertEqual(bot.proc.wait(10), 2)

    def test_stdin_eof_exits_cleanly(self):
        bot = self.start()
        bot.online()
        assert bot.proc.stdin is not None
        bot.proc.stdin.close()
        self.assertEqual(bot.proc.wait(10), 0)

    def test_token_is_never_printed(self):
        bot = self.start()
        bot.online()
        bot.ask("guilds")
        self.assertNotIn(self.fake.token, json.dumps(bot.seen))


if __name__ == "__main__":
    unittest.main()
