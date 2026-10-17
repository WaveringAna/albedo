"""Discord bot process for one albedo session.

The daemon runs this as a child and speaks JSON lines over stdin and stdout:
requests with an integer "id" come in, "reply" lines go out, and "status",
"fatal" and "message" lines are pushed as they happen. The token arrives in
ALBEDO_DISCORD_TOKEN and the REST base in ALBEDO_DISCORD_API. Logs go to stderr.
"""

from __future__ import annotations

import asyncio
import json
import os
import random
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable

from albedo_plugins.ws import ConnectionClosed, SimpleWebSocketClient

DEFAULT_API = "https://discord.com/api/v10"
# Guilds, messages, reactions, DMs, DM reactions, and message content.
INTENTS = (1 << 0) | (1 << 9) | (1 << 10) | (1 << 12) | (1 << 13) | (1 << 15)
MAX_CONTENT = 2000
THREAD_TYPES = (10, 11, 12)
LISTED_TYPES = (0, 2, 4, 5, 15)
BACKOFF_MIN, BACKOFF_MAX = 1.0, 60.0
FATAL_CLOSES = {
    4004: "authentication failed: Discord rejected the bot token",
    4010: "invalid shard sent to the gateway",
    4011: "sharding required",
    4012: "invalid gateway API version",
    4013: "invalid intents",
    4014: "disallowed intents: enable the Message Content intent in the Discord developer portal",
}
# Closes after which the session cannot be resumed: identify afresh.
FRESH_CLOSES = {4007, 4009}
ALLOWED_MENTIONS = {"parse": ["users"], "replied_user": True}


class RestError(Exception):
    def __init__(self, status: int, message: str) -> None:
        super().__init__(f"HTTP {status}: {message}")
        self.status = status


def log(text: str) -> None:
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def emit(line: dict[str, Any]) -> None:
    """Write one JSON line. The event loop is single-threaded, so lines never interleave."""
    sys.stdout.write(json.dumps(line, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def split_content(text: str, limit: int = MAX_CONTENT) -> list[str]:
    """Pieces of at most `limit` characters, cut on line boundaries where possible."""
    if len(text) <= limit:
        return [text]
    parts: list[str] = []
    current = ""
    for line in text.split("\n"):
        candidate = f"{current}\n{line}" if current else line
        if len(candidate) <= limit:
            current = candidate
            continue
        if current:
            parts.append(current)
        while len(line) > limit:
            parts.append(line[:limit])
            line = line[limit:]
        current = line
    if current:
        parts.append(current)
    return parts


def user_view(user: dict[str, Any]) -> dict[str, Any]:
    return {
        "id": str(user.get("id")),
        "username": user.get("username"),
        "global_name": user.get("global_name"),
        "bot": bool(user.get("bot")),
    }


class Rest:
    def __init__(self, base: str, token: str) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def _once(
        self, method: str, path: str, body: Any
    ) -> tuple[int, Any, dict[str, str]]:
        data = None if body is None else json.dumps(body).encode()
        request = urllib.request.Request(self.base + path, data=data, method=method)
        request.add_header("Authorization", f"Bot {self.token}")
        request.add_header("User-Agent", "DiscordBot (albedo, 1)")
        if data is not None:
            request.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status, raw, headers = (
                    response.status,
                    response.read(),
                    response.headers,
                )
        except urllib.error.HTTPError as error:
            status, raw, headers = error.code, error.read(), error.headers
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = {"message": raw.decode("utf-8", errors="replace")[:200]}
        return status, parsed, dict(headers.items())

    async def call(self, method: str, path: str, body: Any = None) -> Any:
        for _ in range(6):
            status, parsed, headers = await asyncio.to_thread(
                self._once, method, path, body
            )
            if status == 429:
                wait = 1.0
                if isinstance(parsed, dict) and "retry_after" in parsed:
                    wait = float(parsed["retry_after"])
                elif "Retry-After" in headers:
                    wait = float(headers["Retry-After"])
                await asyncio.sleep(min(max(wait, 0.0), 60.0))
                continue
            if status >= 400:
                message = parsed.get("message") if isinstance(parsed, dict) else None
                raise RestError(status, message or "request failed")
            return parsed
        raise RestError(429, "rate limited")


class Cache:
    """Guild names and channels (including active threads) from gateway events."""

    def __init__(self) -> None:
        self.guilds: dict[str, dict[str, Any]] = {}
        self.channels: dict[str, dict[str, Any]] = {}

    def put_channel(self, guild_id: str | None, channel: dict[str, Any]) -> None:
        guild_id = guild_id or channel.get("guild_id")
        entry = {
            "id": str(channel["id"]),
            "name": channel.get("name"),
            "type": channel.get("type"),
            "parent_id": channel.get("parent_id"),
            "position": channel.get("position", 0),
            "guild_id": guild_id,
        }
        self.channels[entry["id"]] = entry

    def drop_channel(self, channel_id: str) -> None:
        self.channels.pop(channel_id, None)

    def guild_create(self, guild: dict[str, Any]) -> None:
        gid = str(guild["id"])
        self.guilds[gid] = {"id": gid, "name": guild.get("name")}
        for channel in guild.get("channels") or []:
            self.put_channel(gid, channel)
        for thread in guild.get("threads") or []:
            self.put_channel(gid, thread)

    def guild_delete(self, guild_id: str) -> None:
        self.guilds.pop(guild_id, None)
        for cid in [c for c, v in self.channels.items() if v["guild_id"] == guild_id]:
            del self.channels[cid]

    def guild_view(self) -> list[dict[str, Any]]:
        result = []
        for gid, guild in self.guilds.items():
            listed = [
                {
                    "id": c["id"],
                    "name": c["name"],
                    "type": c["type"],
                    "parent_id": c["parent_id"],
                    "position": c["position"],
                }
                for c in self.channels.values()
                if c["guild_id"] == gid and c["type"] in LISTED_TYPES
            ]
            listed.sort(key=lambda c: (c["position"] or 0, int(c["id"])))
            result.append({"id": gid, "name": guild["name"], "channels": listed})
        return result


class Bot:
    def __init__(self, token: str, api: str) -> None:
        self.rest = Rest(api, token)
        self.token = token
        self.cache = Cache()
        self.user: dict[str, Any] | None = None
        self.application_id: str | None = None
        self.session_id: str | None = None
        self.resume_url: str | None = None
        self.seq: int | None = None
        self.state = "connecting"
        self.fatal = False
        self.dm_channels: set[str] = set()
        self.people: dict[str, dict[str, Any]] = {}
        self.ws: SimpleWebSocketClient | None = None

    # -- status ---------------------------------------------------------

    def status(self, state: str, detail: str | None = None) -> None:
        self.state = state
        user = None
        if self.user:
            user = {
                "id": str(self.user["id"]),
                "username": self.user.get("username"),
                "global_name": self.user.get("global_name"),
            }
        emit(
            {
                "type": "status",
                "state": state,
                "detail": detail,
                "user": user,
                "application_id": self.application_id,
            }
        )

    def die(self, detail: str) -> None:
        self.fatal = True
        emit({"type": "fatal", "detail": detail})

    # -- gateway --------------------------------------------------------

    async def gateway_url(self) -> str:
        info = await self.rest.call("GET", "/gateway/bot")
        return str(info["url"])

    async def run_gateway(self) -> None:
        backoff = BACKOFF_MIN
        first = True
        while not self.fatal:
            self.status("connecting" if first else "reconnecting", None)
            first = False
            detail = None
            try:
                base = self.resume_url if self.session_id else None
                if base is None:
                    base = await self.gateway_url()
                ws = await SimpleWebSocketClient.connect(
                    f"{base.rstrip('/')}/?v=10&encoding=json"
                )
                self.ws = ws
                if await self.session(ws):
                    backoff = BACKOFF_MIN
            except ConnectionClosed as closed:
                detail = f"gateway closed ({closed.code}) {closed.reason}".strip()
                if closed.code in FATAL_CLOSES:
                    self.die(FATAL_CLOSES[closed.code])
                    return
                if closed.code in FRESH_CLOSES:
                    self.session_id = None
                    self.seq = None
            except RestError as error:
                detail = str(error)
                if error.status == 401:
                    self.die("authentication failed: Discord rejected the bot token")
                    return
            except (OSError, TimeoutError, ValueError, KeyError) as error:
                detail = f"{type(error).__name__}: {error}"
            finally:
                self.ws = None
            if self.fatal:
                return
            if detail:
                log(detail)
            self.status("reconnecting", detail)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, BACKOFF_MAX)

    async def session(self, ws: SimpleWebSocketClient) -> bool:
        """Run one socket until it should be replaced; True once it reached READY/RESUMED."""
        hello = json.loads(await ws.recv_message())
        interval = hello["d"]["heartbeat_interval"] / 1000
        acked = {"value": True}
        beat = asyncio.create_task(self.heartbeat(ws, interval, acked))
        reached = False
        try:
            await self.handshake(ws)
            while True:
                payload = json.loads(await ws.recv_message())
                op = payload.get("op")
                if payload.get("s") is not None:
                    self.seq = payload["s"]
                if op == 0:
                    reached = await self.dispatch(payload["t"], payload["d"]) or reached
                elif op == 1:
                    await ws.send(json.dumps({"op": 1, "d": self.seq}))
                elif op == 11:
                    acked["value"] = True
                elif op == 7:
                    await ws.close(4000, "reconnect requested")
                    return reached
                elif op == 9:
                    if not payload.get("d"):
                        self.session_id = None
                        self.seq = None
                    await asyncio.sleep(random.uniform(1, 5))
                    await ws.close(4000, "invalid session")
                    return reached
        finally:
            beat.cancel()
            await asyncio.gather(beat, return_exceptions=True)
            await ws.close()

    async def handshake(self, ws: SimpleWebSocketClient) -> None:
        if self.session_id and self.seq is not None:
            body = {
                "op": 6,
                "d": {
                    "token": self.token,
                    "session_id": self.session_id,
                    "seq": self.seq,
                },
            }
        else:
            body = {
                "op": 2,
                "d": {
                    "token": self.token,
                    "intents": INTENTS,
                    "properties": {
                        "os": sys.platform,
                        "browser": "albedo",
                        "device": "albedo",
                    },
                },
            }
        await ws.send(json.dumps(body))

    async def heartbeat(
        self, ws: SimpleWebSocketClient, interval: float, acked: dict[str, bool]
    ) -> None:
        await asyncio.sleep(interval * random.random())
        while True:
            if not acked["value"]:
                await ws.close(4000, "heartbeat not acknowledged")
                return
            acked["value"] = False
            try:
                await ws.send(json.dumps({"op": 1, "d": self.seq}))
            except ConnectionClosed:
                return
            await asyncio.sleep(interval)

    async def dispatch(self, name: str, data: dict[str, Any]) -> bool:
        """Handle one event; True when it marks the session as live."""
        cache = self.cache
        if name == "READY":
            self.user = data["user"]
            self.session_id = data["session_id"]
            self.resume_url = data.get("resume_gateway_url")
            self.application_id = (data.get("application") or {}).get("id")
            self.status("online", None)
            return True
        if name == "RESUMED":
            self.status("online", None)
            return True
        if name == "GUILD_CREATE":
            cache.guild_create(data)
        elif name == "GUILD_UPDATE":
            if str(data["id"]) in cache.guilds:
                cache.guilds[str(data["id"])]["name"] = data.get("name")
        elif name == "GUILD_DELETE":
            if not data.get("unavailable"):
                cache.guild_delete(str(data["id"]))
        elif name in (
            "CHANNEL_CREATE",
            "CHANNEL_UPDATE",
            "THREAD_CREATE",
            "THREAD_UPDATE",
        ):
            if data.get("guild_id"):
                cache.put_channel(str(data["guild_id"]), data)
            elif data.get("type") == 1:
                self.dm_channels.add(str(data["id"]))
        elif name in ("CHANNEL_DELETE", "THREAD_DELETE"):
            cache.drop_channel(str(data["id"]))
        elif name == "THREAD_LIST_SYNC":
            for thread in data.get("threads") or []:
                cache.put_channel(str(data["guild_id"]), thread)
        elif name == "MESSAGE_CREATE":
            emit(
                {"type": "message", "backfill": False, "message": self.normalize(data)}
            )
        elif name == "MESSAGE_REACTION_ADD":
            await self.reaction(data)
        return False

    async def reactor(self, user_id: str, member: dict[str, Any]) -> dict[str, Any]:
        """Who reacted: a server event says, a DM event does not, so ask once."""
        if member.get("user"):
            return member["user"]
        if user_id not in self.people:
            try:
                self.people[user_id] = await asyncio.wait_for(
                    self.rest.call("GET", f"/users/{user_id}"), 5
                )
            except (RestError, OSError, TimeoutError) as error:
                log(f"reactor {user_id}: {error}")
                return {}
        return self.people[user_id]

    async def reaction(self, data: dict[str, Any]) -> None:
        user_id = str(data["user_id"])
        if self.user and user_id == str(self.user["id"]):
            return
        member = data.get("member") or {}
        author = {
            "username": user_id,
            **await self.reactor(user_id, member),
            "id": user_id,
        }
        channel_id = str(data["channel_id"])
        channel = self.cache.channels.get(channel_id) or {}
        guild_id = data.get("guild_id")
        guild = self.cache.guilds.get(str(guild_id)) or {}
        emoji = data["emoji"]
        symbol = emoji.get("name") or "unknown emoji"
        if emoji.get("id"):
            prefix = "a" if emoji.get("animated") else ""
            symbol = f"<{prefix}:{symbol}:{emoji['id']}>"
        emit(
            {
                "type": "reaction",
                "reaction": {
                    "id": f"{self.session_id}:{self.seq}",
                    "message_id": str(data["message_id"]),
                    "channel_id": channel_id,
                    "guild_id": str(guild_id) if guild_id else None,
                    "guild_name": guild.get("name"),
                    "channel_name": channel.get("name"),
                    "parent_id": channel.get("parent_id")
                    if channel.get("type") in THREAD_TYPES
                    else None,
                    "author": user_view(author),
                    "nick": member.get("nick"),
                    "emoji": symbol,
                    "message_author_id": data.get("message_author_id"),
                },
            }
        )

    # -- messages -------------------------------------------------------

    def normalize(self, raw: dict[str, Any]) -> dict[str, Any]:
        channel_id = str(raw["channel_id"])
        cached = self.cache.channels.get(channel_id)
        guild_id = raw.get("guild_id") or (cached["guild_id"] if cached else None)
        guild_id = str(guild_id) if guild_id else None
        guild = self.cache.guilds.get(guild_id) if guild_id else None
        parent_id = None
        if cached and cached["type"] in THREAD_TYPES and cached["parent_id"]:
            parent_id = str(cached["parent_id"])
        author = raw.get("author") or {}
        mentions = [
            {
                "id": str(m["id"]),
                "username": m.get("username"),
                "bot": bool(m.get("bot")),
            }
            for m in raw.get("mentions") or []
        ]
        me = str(self.user["id"]) if self.user else None
        reference = raw.get("message_reference") or {}
        reply_to = reference.get("message_id")
        return {
            "id": str(raw["id"]),
            "channel_id": channel_id,
            "guild_id": guild_id,
            "guild_name": guild["name"] if guild else None,
            "channel_name": cached["name"] if cached else None,
            "parent_id": parent_id,
            "is_dm": guild_id is None,
            "content": raw.get("content") or "",
            "timestamp": raw.get("timestamp"),
            "author": user_view(author),
            "nick": (raw.get("member") or {}).get("nick"),
            "mentions": mentions,
            "mentions_me": me is not None and any(m["id"] == me for m in mentions),
            "reply_to": str(reply_to) if reply_to else None,
            "attachments": [
                {
                    "filename": a.get("filename"),
                    "url": a.get("url"),
                    "content_type": a.get("content_type"),
                    "size": a.get("size"),
                }
                for a in raw.get("attachments") or []
            ],
        }

    async def know_channel(self, channel_id: str) -> None:
        """REST messages carry no guild_id, so look an unseen channel up once."""
        if channel_id in self.cache.channels or channel_id in self.dm_channels:
            return
        info = await self.rest.call("GET", f"/channels/{channel_id}")
        if info.get("guild_id"):
            self.cache.put_channel(str(info["guild_id"]), info)
        else:
            self.dm_channels.add(channel_id)

    async def fetch_messages(
        self, channel_id: str, query: dict[str, Any]
    ) -> list[dict[str, Any]]:
        await self.know_channel(channel_id)
        qs = urllib.parse.urlencode({k: v for k, v in query.items() if v is not None})
        raw = await self.rest.call("GET", f"/channels/{channel_id}/messages?{qs}")
        raw.sort(key=lambda m: int(m["id"]))
        return [self.normalize(m) for m in raw]

    # -- operations -----------------------------------------------------

    async def post_parts(
        self, channel_id: str, content: str, reply_to: str | None
    ) -> dict[str, Any]:
        ids = []
        for index, part in enumerate(split_content(content)):
            body: dict[str, Any] = {
                "content": part,
                "allowed_mentions": ALLOWED_MENTIONS,
            }
            if reply_to and index == 0:
                body["message_reference"] = {
                    "message_id": reply_to,
                    "fail_if_not_exists": False,
                }
            sent = await self.rest.call(
                "POST", f"/channels/{channel_id}/messages", body
            )
            ids.append(str(sent["id"]))
        return {"ids": ids, "channel_id": channel_id}

    async def op_send(self, req: dict[str, Any]) -> Any:
        return await self.post_parts(
            str(req["channel_id"]), req["content"], req.get("reply_to")
        )

    async def op_dm(self, req: dict[str, Any]) -> Any:
        channel = await self.rest.call(
            "POST", "/users/@me/channels", {"recipient_id": str(req["user_id"])}
        )
        channel_id = str(channel["id"])
        self.dm_channels.add(channel_id)
        return await self.post_parts(channel_id, req["content"], None)

    async def op_history(self, req: dict[str, Any]) -> Any:
        limit = max(1, min(int(req.get("limit") or 20), 100))
        return await self.fetch_messages(
            str(req["channel_id"]), {"limit": limit, "before": req.get("before")}
        )

    async def op_react(self, req: dict[str, Any]) -> Any:
        emoji = urllib.parse.quote(req["emoji"], safe="")
        await self.rest.call(
            "PUT",
            f"/channels/{req['channel_id']}/messages/{req['message_id']}/reactions/{emoji}/@me",
        )
        return None

    async def op_guilds(self, req: dict[str, Any]) -> Any:
        return self.cache.guild_view()

    async def op_user(self, req: dict[str, Any]) -> Any:
        return user_view(await self.rest.call("GET", f"/users/{req['user_id']}"))

    async def op_catch_up(self, req: dict[str, Any]) -> Any:
        count = 0
        for entry in req.get("channels") or []:
            try:
                messages = await self.fetch_messages(
                    str(entry["channel_id"]),
                    {"after": str(entry["after"]), "limit": 50},
                )
            except RestError as error:
                log(f"catch_up {entry.get('channel_id')}: {error}")
                continue
            for message in messages:
                emit({"type": "message", "backfill": True, "message": message})
                count += 1
        return {"messages": count}

    async def handle(self, req: dict[str, Any]) -> None:
        handlers: dict[str, Callable[[dict[str, Any]], Any]] = {
            "send": self.op_send,
            "dm": self.op_dm,
            "history": self.op_history,
            "react": self.op_react,
            "guilds": self.op_guilds,
            "user": self.op_user,
            "catch_up": self.op_catch_up,
        }
        request_id = req.get("id")
        try:
            handler = handlers.get(str(req.get("op")))
            if handler is None:
                raise ValueError(f"unknown op: {req.get('op')}")
            result = await handler(req)
            emit({"type": "reply", "id": request_id, "ok": True, "result": result})
        except Exception as error:  # every failure becomes an error reply
            emit({"type": "reply", "id": request_id, "ok": False, "error": str(error)})


async def read_commands(bot: Bot, tasks: set[asyncio.Task[None]]) -> None:
    """Run one task per stdin line; return at EOF."""
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader(limit=16 * 1024 * 1024)
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(reader), sys.stdin
    )
    while True:
        try:
            line = await reader.readline()
        except ValueError:
            log("dropped an oversized command line")
            continue
        if not line:
            return
        try:
            req = json.loads(line)
        except ValueError:
            log("ignored a line that is not JSON")
            continue
        if isinstance(req, dict):
            task = asyncio.create_task(bot.handle(req))
            tasks.add(task)
            task.add_done_callback(tasks.discard)


async def main_async() -> int:
    token = os.environ.get("ALBEDO_DISCORD_TOKEN", "")
    if not token:
        emit({"type": "fatal", "detail": "ALBEDO_DISCORD_TOKEN is not set"})
        return 2
    api = os.environ.get("ALBEDO_DISCORD_API") or DEFAULT_API
    bot = Bot(token, api)
    tasks: set[asyncio.Task[None]] = set()
    gateway = asyncio.create_task(bot.run_gateway())
    stdin = asyncio.create_task(read_commands(bot, tasks))
    await asyncio.wait({gateway, stdin}, return_when=asyncio.FIRST_COMPLETED)
    code = 2 if bot.fatal else 0
    for task in (gateway, stdin, *tasks):
        task.cancel()
    await asyncio.gather(gateway, stdin, *tasks, return_exceptions=True)
    return code


def main() -> int:
    try:
        return asyncio.run(main_async())
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
