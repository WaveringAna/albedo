"""Discord bots wake their session through the daemon's event inbox: a
whitelisted DM steers it, a refused one becomes a request the human allows,
and channel messages follow each channel's delivery, against a fake Discord
the real bot process connects to."""

import json
import re
import sqlite3
import time
import unittest
import urllib.error

from discord_fake_support import FakeDiscord
from harness import Albedo, Provider, exclusive, python, text, wait_until

OWNER = "100000000000000010"
STRANGER = "100000000000000020"
OTHER_BOT = "100000000000000030"
GUILD = "200000000000000001"
TURN = "300000000000000001"
TOOL = "300000000000000002"
QUIET = "300000000000000003"
MENTIONS = "300000000000000004"
THREAD = "300000000000000005"
HOLD = "hold the turn open"
OWNER_PING = "ping from owner"
NAMES = "use names and numbers"


def visible(item):
    return json.dumps(item, ensure_ascii=False)


def shown(text):
    """`text` as it reads inside a JSON string, which `visible` produces."""
    return json.dumps(text, ensure_ascii=False)[1:-1]


# exclusive: the daemon's bot processes must reach this test's fake Discord
# (ALBEDO_DISCORD_API), and the discord extension is enabled globally.
@exclusive
class DiscordTests(unittest.TestCase):
    def setUp(self):
        self.fake = FakeDiscord()
        self.addCleanup(self.fake.stop)
        self.fake.add_user(OWNER, "ana", global_name="Ana")
        self.fake.add_user(STRANGER, "bob", global_name="Bob")
        self.fake.add_user(OTHER_BOT, "otherbot", global_name="Other", bot=True)
        self.fake.add_guild(
            GUILD,
            "Lab",
            channels=[
                {"id": TURN, "name": "turn"},
                {"id": TOOL, "name": "tool"},
                {"id": QUIET, "name": "quiet"},
                {"id": MENTIONS, "name": "mentions"},
            ],
            threads=[{"id": THREAD, "name": "side", "parent_id": TOOL}],
        )
        self.provider = Provider(self.script)
        self.addCleanup(self.provider.close)

        def prepare(app):
            app.env["ALBEDO_DISCORD_API"] = self.fake.api_url
            app.write_extensions({"enabled": {"discord": True}})

        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.started = self.app.root / "hold-started"
        self.gate = self.app.root / "hold-gate"
        self.session = self.app.session()

    def script(self, request):
        last = request["input"][-1]
        seen = visible(last)
        if last.get("type") == "function_call_output":
            return text("tool done")
        if HOLD in seen:
            return python(
                "import asyncio, pathlib\n"
                f"pathlib.Path({str(self.started)!r}).write_text('1')\n"
                f"while not pathlib.Path({str(self.gate)!r}).exists():\n"
                "    await asyncio.sleep(0.05)\n"
                "print('released')"
            )
        if OWNER_PING in seen:
            found = re.search(r"· (c\d+)\] @\w+ \(\w+\) · message (\d+)", seen)
            assert found, seen
            channel, message = found.groups()
            return python(
                f"sent = await discord.send({channel!r}, 'pong', reply_to={message!r})\n"
                "state = await discord.status()\n"
                "try:\n"
                f"    await discord.dm({STRANGER!r}, 'unsolicited')\n"
                "except DiscordError as refused:\n"
                "    print('DM_REFUSED', refused)\n"
                "print('SENT', sent.channel, state.state, state.user['username'])"
            )
        if NAMES in seen:
            return python(
                "listed = await discord.channels()\n"
                "print('CHANNELS', ' ; '.join(\n"
                "    f'{c.handle}|{c.name}|{c.guild}|{c.delivery}' for c in listed))\n"
                "reply = await discord.send('tool', 'by name', reply_to=1)\n"
                "await discord.react('c1', reply.messages[0], '✅')\n"
                "rows = await discord.history('#tool', limit=10)\n"
                "print('HISTORY', ' ; '.join(\n"
                "    f'{r.number}|{r.author}|{r.content}|{r.reply_to}' for r in rows))\n"
                "print('SENT', reply.messages, reply.channel)\n"
                "for call in (\n"
                "    lambda: discord.react('tool', 99, '👍'),\n"
                "    lambda: discord.send('nowhere', 'x'),\n"
                "):\n"
                "    try:\n"
                "        await call()\n"
                "    except DiscordError as refused:\n"
                "        print('REFUSED', refused)"
            )
        return text("noted")

    # -- fixtures -------------------------------------------------------

    def create_bot(self):
        with self.app.api(
            "/extensions/discord/bots",
            {
                "session_id": self.session,
                "name": "helper",
                "token": self.fake.token,
                "owner_id": OWNER,
            },
        ) as response:
            self.assertEqual(response.status, 201)
            bot = json.load(response)
        self.assertNotIn(self.fake.token, json.dumps(bot))
        self.route = "/extensions/discord/bots/" + bot["id"]
        self.wait_state("online")
        self.fake.wait_for_gateway(timeout=10)
        return self.bot()

    def wait_state(self, state):
        deadline = time.monotonic() + 30
        while (bot := self.bot())["state"] != state:
            self.assertLess(time.monotonic(), deadline, f"never {state}: {bot}")
            time.sleep(0.1)

    def bot(self):
        with self.app.api(self.route) as response:
            return json.load(response)

    def put_channel(self, channel, delivery, mentions_only=False):
        with self.app.api(
            f"{self.route}/channels/{channel}",
            {
                "delivery": delivery,
                "mentions_only": mentions_only,
                "guild_id": GUILD,
                "guild_name": "Lab",
                "channel_name": None,
            },
            method="PUT",
        ) as response:
            return json.load(response)

    def database(self):
        return sqlite3.connect(self.app.home / "albedo.sqlite", timeout=10)

    def letters(self, bot, *messages):
        ids = [f"discord-{bot}-{message}" for message in messages]
        with self.database() as database:
            return database.execute(
                f"SELECT count(*) FROM mail WHERE id IN ({','.join('?' * len(ids))})",
                ids,
            ).fetchone()[0]

    def requests(self):
        return [entry["request"] for entry in self.provider.requests]

    def first_seen(self, needle):
        """The index of the provider request that first carried `needle`."""
        for index, request in enumerate(self.requests()):
            if needle in visible(request):
                return index
        return None

    def wait_seen(self, needle, seconds=40):
        wait_until(
            lambda: self.first_seen(needle) is not None,
            seconds,
            f"the model never saw {needle!r}",
        )

    def post(self, channel, content, author=None, **extra):
        author = author or {"id": OWNER, "username": "ana", "global_name": "Ana"}
        return self.fake.post(channel, content, author=author, **extra)

    # -- scenarios ------------------------------------------------------

    def test_removed_automated_creation_endpoints_are_not_found(self):
        requests = [
            ("/extensions/discord/account", None, "GET"),
            ("/extensions/discord/account", {"token": "unused"}, "PUT"),
            (
                "/extensions/discord/provisions",
                {"session_id": self.session, "name": "unused", "guild_id": None},
                "POST",
            ),
        ]
        for path, body, method in requests:
            with self.assertRaises(urllib.error.HTTPError) as missing:
                self.app.api(path, body, method=method)
            self.assertEqual(missing.exception.code, 404)
            self.assertEqual(json.load(missing.exception)["code"], "not_found")

        # The supported manual path still creates and connects a bot.
        bot = self.create_bot()
        self.assertEqual(bot["state"], "online")

    def test_dms_are_whitelisted_and_the_owner_wakes_the_session(self):
        bot = self.create_bot()
        self.assertEqual(
            bot["user"], {"id": self.fake.bot["id"], "username": "albedo-bot"}
        )
        self.assertEqual(bot["application_id"], self.fake.application_id)
        self.assertIn(f"client_id={self.fake.application_id}", bot["invite_url"])
        with self.app.api("/extensions/discord/bots") as response:
            listed = json.load(response)["items"]
        self.assertEqual([item["id"] for item in listed], [bot["id"]])
        self.assertNotIn(self.fake.token, json.dumps(listed))
        with self.assertRaises(urllib.error.HTTPError) as duplicate:
            self.app.api(
                "/extensions/discord/bots",
                {
                    "session_id": self.session,
                    "name": "again",
                    "token": self.fake.token,
                    "owner_id": OWNER,
                },
            )
        self.assertEqual(duplicate.exception.code, 409)

        owner_dm = self.fake.dm_channel(OWNER)
        ping = self.post(owner_dm, OWNER_PING)
        self.wait_seen(OWNER_PING)
        self.assertIn(
            "[discord dm · c1] @ana (Ana) · message 1",
            visible(self.requests()[self.first_seen(OWNER_PING)]),
        )
        sent = self.fake.wait_for_sent(1, timeout=40)
        self.assertEqual(sent[0]["content"], "pong")
        self.assertEqual(sent[0]["message_reference"]["message_id"], ping)
        self.app.idle(self.session, timeout=40)
        outputs = visible(self.requests()[-1])
        self.assertIn("DM_REFUSED", outputs)
        self.assertIn("SENT c1 online albedo-bot", outputs)

        stranger_dm = self.fake.dm_channel(STRANGER)
        stranger = {"id": STRANGER, "username": "bob", "global_name": "Bob"}
        refused = self.post(stranger_dm, "let me in", author=stranger)

        def requests():
            with self.app.api(self.route + "/dms") as response:
                return json.load(response)

        wait_until(lambda: requests()["requests"], 20, "the refused DM made no request")
        dms = requests()
        self.assertEqual(dms["owner"], {"user_id": OWNER, "name": None})
        self.assertEqual(dms["allowed"], [])
        self.assertEqual(
            [
                (item["user_id"], item["username"], item["preview"], item["count"])
                for item in dms["requests"]
            ],
            [(STRANGER, "bob", "let me in", 1)],
        )
        self.assertEqual(self.letters(bot["id"], refused), 0)
        with self.app.api(
            f"{self.route}/dms/{STRANGER}", {"name": None}, method="PUT"
        ) as response:
            allowed = json.load(response)
        self.assertEqual((allowed["user_id"], allowed["name"]), (STRANGER, "Bob"))
        self.assertEqual(requests()["requests"], [])
        self.assertEqual(self.bot()["allowed"], 1)
        self.post(stranger_dm, "thanks for allowing me", author=stranger)
        self.wait_seen("thanks for allowing me")
        self.assertIsNone(self.first_seen("let me in"))
        with self.assertRaises(urllib.error.HTTPError) as owner:
            self.app.api(f"{self.route}/dms/{OWNER}", method="DELETE")
        self.assertEqual(owner.exception.code, 400)

        self.app.idle(self.session, timeout=40)
        revision = self.bot()["revision"]
        with self.app.api(
            f"{self.route}?revision={revision}", method="DELETE"
        ) as response:
            self.assertEqual(json.load(response), {"deleted": bot["id"]})
        self.fake.wait_for(
            lambda: not self.fake._live(), 20, "the bot stayed connected"
        )
        with self.database() as database:
            for table in ("discord_allowed", "discord_cursors", "discord_requests"):
                self.assertEqual(
                    database.execute(
                        f"SELECT count(*) FROM {table} WHERE bot=?", (bot["id"],)
                    ).fetchone()[0],
                    0,
                    table,
                )
        with self.assertRaises(urllib.error.HTTPError) as gone:
            self.app.api(self.route)
        self.assertEqual(gone.exception.code, 404)

    def test_channel_messages_follow_each_channel_delivery(self):
        bot = self.create_bot()
        with self.app.api(self.route + "/guilds") as response:
            guilds = json.load(response)["guilds"]
        channels = {item["id"]: item for item in guilds[0]["channels"]}
        self.assertEqual(guilds[0]["name"], "Lab")
        self.assertEqual(channels[TURN]["delivery"], "off")
        self.assertEqual(
            self.put_channel(TURN, "turn"),
            {"channel_id": TURN, "delivery": "turn", "mentions_only": False},
        )
        self.put_channel(TOOL, "tool")
        self.put_channel(MENTIONS, "tool", mentions_only=True)
        with self.app.api(self.route + "/guilds") as response:
            channels = {
                item["id"]: item
                for item in json.load(response)["guilds"][0]["channels"]
            }
        self.assertEqual(
            [
                (channels[c]["delivery"], channels[c]["mentions_only"])
                for c in (TURN, TOOL, QUIET, MENTIONS)
            ],
            [("turn", False), ("tool", False), ("off", False), ("tool", True)],
        )

        own = {"id": self.fake.bot["id"], "username": "albedo-bot", "bot": True}
        other = {
            "id": OTHER_BOT,
            "username": "otherbot",
            "global_name": "Other",
            "bot": True,
        }
        ignored = [
            self.post(QUIET, "nobody configured this"),
            self.post(TOOL, "my own words", author=own),
            self.post(MENTIONS, "no mention here"),
        ]
        delivered = [
            self.post(MENTIONS, "mentioning the bot", mentions=[self.fake.bot["id"]]),
            self.post(TOOL, "hello from another albedo", author=other),
            self.post(THREAD, "a thread under tool"),
        ]
        wait_until(
            lambda: self.letters(bot["id"], *delivered) == 3,
            20,
            "the delivered messages made no letters",
        )
        self.assertEqual(self.letters(bot["id"], *ignored), 0)
        self.wait_seen("hello from another albedo")
        self.wait_seen("a thread under tool")
        self.assertRegex(
            visible(self.requests()),
            r"\[discord #tool in Lab · c\d+\] @otherbot \(Other, bot\) · message 1\b",
        )
        self.app.idle(self.session, timeout=40)
        for words in ("nobody configured this", "my own words", "no mention here"):
            self.assertIsNone(self.first_seen(words), words)

        self.app.prompt(self.session, HOLD).close()
        wait_until(self.started.exists, 30, "the held cell never started")
        steering = self.post(TOOL, "steer after the tool call")
        queued = [self.post(TURN, "first queued"), self.post(TURN, "second queued")]
        wait_until(
            lambda: self.letters(bot["id"], steering, *queued) == 3,
            20,
            "the held turn's messages made no letters",
        )
        self.gate.write_text("go")
        self.wait_seen("steer after the tool call")
        self.wait_seen("first queued")
        self.app.idle(self.session, timeout=40)
        steered = self.first_seen("steer after the tool call")
        self.assertIn("released", visible(self.requests()[steered]))
        self.assertGreater(self.first_seen("first queued"), steered)
        self.assertEqual(
            self.first_seen("first queued"), self.first_seen("second queued")
        )
        self.assertNotIn("first queued", visible(self.requests()[steered]))

    def test_reactions_to_bot_replies_reach_the_session_once(self):
        bot = self.create_bot()
        channel = self.fake.dm_channel(OWNER)
        self.post(channel, OWNER_PING)
        self.wait_seen(OWNER_PING)
        sent = self.fake.wait_for_sent(1, timeout=40)[0]
        self.app.idle(self.session, timeout=40)

        event = self.fake.react(channel, sent["id"], OWNER)
        self.wait_seen("👍")
        self.app.idle(self.session, timeout=40)
        received = visible(self.requests()[self.first_seen("👍")])
        self.assertIn(
            shown(
                '[discord dm reaction · c1] @ana (Ana) reacted 👍 to your message 2: "pong"'
            ),
            received,
        )
        for snowflake in (sent["id"], channel):
            self.assertNotIn(snowflake, received)
        self.assertNotIn("discord.com/channels", received)
        self.fake.drop_connection()
        self.fake.wait_for_resumes(1, timeout=30)
        self.fake.replay(event)
        self.fake.replay(event)
        barrier = self.fake.react(channel, sent["id"], OWNER, "✅")
        self.wait_seen("✅")
        self.app.idle(self.session, timeout=40)
        with self.database() as database:
            rows = database.execute(
                "SELECT id FROM mail WHERE id LIKE ? ORDER BY id",
                (f"discord-{bot['id']}-reaction-%",),
            ).fetchall()
        self.assertEqual(
            sorted(row[0] for row in rows),
            sorted(f"discord-{bot['id']}-reaction-{key}" for key in (event, barrier)),
        )
        self.assertEqual(visible(self.requests()[-1]).count("👍"), 1)

    def test_reactions_keep_channel_delivery_and_dm_permissions(self):
        bot = self.create_bot()
        self.put_channel(TURN, "turn")
        self.put_channel(TOOL, "tool")
        self.put_channel(MENTIONS, "tool", mentions_only=True)
        own = self.fake.bot
        targets = {
            channel: self.post(channel, "bot proposal", author=own)
            for channel in (TURN, TOOL, QUIET, MENTIONS, THREAD)
        }
        unrelated = self.post(MENTIONS, "not addressed to the bot")
        mentioned = self.post(MENTIONS, "addressed to the bot", mentions=[own["id"]])
        self.wait_seen("addressed to the bot")
        self.app.idle(self.session, timeout=40)
        with self.database() as database:
            cursors = database.execute(
                "SELECT channel_id,last_seen FROM discord_cursors WHERE bot=? ORDER BY channel_id",
                (bot["id"],),
            ).fetchall()
        stranger_dm = self.fake.dm_channel(STRANGER)
        stranger_target = self.post(stranger_dm, "unapproved DM target", author=own)
        ignored = [
            self.fake.react(QUIET, targets[QUIET], OWNER),
            self.fake.react(TOOL, targets[TOOL], own["id"]),
            self.fake.react(MENTIONS, unrelated, OWNER),
            self.fake.react(stranger_dm, stranger_target, STRANGER),
        ]
        self.app.prompt(self.session, HOLD).close()
        wait_until(self.started.exists, 30, "the held cell never started")
        steering = [
            self.fake.react(THREAD, targets[THREAD], OWNER, "👍"),
            self.fake.react(MENTIONS, targets[MENTIONS], OWNER, "✅"),
            self.fake.react(MENTIONS, mentioned, OWNER, {"id": "456", "name": "yes"}),
        ]
        queued = self.fake.react(TURN, targets[TURN], OWNER, "🎉")
        accepted = steering + [queued]

        def reaction_rows():
            with self.database() as database:
                return dict(
                    database.execute(
                        "SELECT id,kind FROM mail WHERE id LIKE ?",
                        (f"discord-{bot['id']}-reaction-%",),
                    )
                )

        wait_until(
            lambda: len(reaction_rows()) == len(accepted), 20, "missing reactions"
        )
        rows = reaction_rows()
        for event in steering:
            self.assertEqual(
                rows[f"discord-{bot['id']}-reaction-{event}"], "event_tool"
            )
        self.assertEqual(rows[f"discord-{bot['id']}-reaction-{queued}"], "event_turn")
        for event in ignored:
            self.assertNotIn(f"discord-{bot['id']}-reaction-{event}", rows)
        with self.database() as database:
            self.assertEqual(
                database.execute("SELECT count(*) FROM discord_requests").fetchone()[0],
                0,
            )
            self.assertEqual(
                database.execute(
                    "SELECT channel_id,last_seen FROM discord_cursors WHERE bot=? ORDER BY channel_id",
                    (bot["id"],),
                ).fetchall(),
                cursors,
            )
        self.gate.write_text("go")
        self.wait_seen("👍")
        self.wait_seen("🎉")
        self.app.idle(self.session, timeout=40)
        first = visible(self.requests()[self.first_seen("👍")])
        self.assertIn("released", first)
        self.assertIn("<:yes:456>", first)
        self.assertNotIn("🎉", first)
        self.assertGreater(self.first_seen("🎉"), self.first_seen("👍"))

    def test_channels_and_messages_are_named_by_handle_and_number(self):
        self.create_bot()
        self.put_channel(TOOL, "tool")
        hello = self.post(TOOL, "hello there", nick="Annie")
        self.wait_seen("hello there")
        self.assertRegex(
            visible(self.requests()[self.first_seen("hello there")]),
            r"\[discord #tool in Lab · c1\] @ana \(Annie\) · message 1\b",
        )
        self.app.idle(self.session, timeout=40)

        self.app.prompt(self.session, NAMES).close()
        sent = self.fake.wait_for_sent(1, timeout=40)[0]
        self.app.idle(self.session, timeout=40)
        self.assertEqual(sent["content"], "by name")
        self.assertEqual(sent["message_reference"]["message_id"], hello)
        self.assertEqual(
            self.fake.wait_for_reaction(),
            [{"channel_id": TOOL, "message_id": sent["id"], "emoji": "✅"}],
        )
        output = visible(self.requests()[-1])
        for line in (
            "CHANNELS c1|tool|Lab|tool",
            "HISTORY 1|Annie|hello there|None ; 2|albedo-bot|by name|1",
            "SENT [2] c1",
            "REFUSED no message 99 in that channel",
            "REFUSED no channel is called nowhere",
        ):
            self.assertIn(line, output)

        # A person who reacts to the bot's message is named by their server
        # nickname, and the message by its number and the start of its text.
        self.fake.react(TOOL, sent["id"], OWNER, "👍", nick="Annie")
        self.wait_seen("reacted 👍")
        self.assertIn(
            shown(
                '[discord reaction #tool in Lab · c1] @ana (Annie) reacted 👍 to your message 2: "by name"'
            ),
            visible(self.requests()[self.first_seen("reacted 👍")]),
        )

    def test_catch_up_after_a_reconnect_delivers_once(self):
        bot = self.create_bot()
        self.put_channel(TOOL, "tool")
        self.post(TOOL, "before the drop")
        self.wait_seen("before the drop")
        self.app.idle(self.session, timeout=40)
        self.fake.drop_connection()
        missed = self.post(TOOL, "posted while away")
        self.fake.wait_for_resumes(1, timeout=30)
        self.fake.wait_for(
            lambda: ("GET", f"/channels/{TOOL}/messages") in self.fake.requests,
            30,
            "catch_up never asked for missed messages",
        )
        self.wait_seen("posted while away")
        self.app.idle(self.session, timeout=40)
        self.assertEqual(self.letters(bot["id"], missed), 1)
        latest = visible(self.requests()[-1])
        self.assertEqual(latest.count("posted while away"), 1, latest)
        self.assertEqual(latest.count("before the drop"), 1, latest)
        with self.database() as database:
            (cursor,) = database.execute(
                "SELECT last_seen FROM discord_cursors WHERE bot=? AND channel_id=?",
                (bot["id"], TOOL),
            ).fetchone()
        self.assertEqual(cursor, missed)

    def test_a_fatal_close_stops_the_bot_until_its_token_changes(self):
        self.fake.reject_token()
        with self.app.api(
            "/extensions/discord/bots",
            {
                "session_id": self.session,
                "name": "helper",
                "token": self.fake.token,
                "owner_id": OWNER,
            },
        ) as response:
            bot = json.load(response)
        self.route = "/extensions/discord/bots/" + bot["id"]
        self.wait_state("failed")
        self.assertIn("token", self.bot()["detail"])
        connections = self.fake.connections
        time.sleep(3)
        self.assertEqual(self.fake.connections, connections, "a fatal bot reconnected")
        with self.assertRaises(urllib.error.HTTPError) as offline:
            self.app.api(self.route + "/guilds")
        self.assertEqual(offline.exception.code, 503)
        with self.assertRaises(urllib.error.HTTPError) as stale:
            self.app.api(
                self.route,
                {"revision": bot["revision"] + 5, "enabled": False},
                method="PATCH",
            )
        self.assertEqual(stale.exception.code, 412)
        with self.app.api(
            self.route, {"revision": bot["revision"], "enabled": False}, method="PATCH"
        ) as response:
            patched = json.load(response)
        self.assertEqual((patched["enabled"], patched["state"]), (False, "disabled"))


if __name__ == "__main__":
    unittest.main()
