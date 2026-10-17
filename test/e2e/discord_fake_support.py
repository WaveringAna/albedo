"""A fake Discord for tests: REST and a gateway WebSocket on one local port.

    fake = FakeDiscord()
    fake.add_guild("200", "Guild", channels=[{"id": "300", "name": "general"}])
    env["ALBEDO_DISCORD_API"] = fake.api_url      # and ALBEDO_DISCORD_TOKEN = fake.token
    ...
    fake.post("300", "hi", guild_id="200", mentions=[fake.bot["id"]])
    fake.wait_for_sent(1, timeout=10)
    fake.stop()

The server runs on its own thread and event loop. Every public method is safe
to call from the test thread: state is only touched on the server loop.
Events posted while no socket is live are kept and replayed to a RESUME, as
Discord does; a fresh IDENTIFY starts from the current state.
"""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import sys
import threading
import time
import urllib.parse
from typing import Any, Callable

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
SNOWFLAKE_BASE = 110_000_000_000_000_000


def chrome_installed() -> bool:
    """Whether the browser plugin can find a Chrome or Chromium to drive.

    Browser-mode provisioning opens a real browser, so suites that exercise it
    skip where there is none. The plugin's own resolver decides, since it knows
    about chrome-headless-shell and each platform's install locations.
    """
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
    try:
        from albedo_plugins.browser.launch import _executable
    except ImportError:
        return False
    for headless in (True, False):
        try:
            _executable(None, headless=headless)
            return True
        except Exception:
            continue
    return False


CHROME = chrome_installed()


def b64url(text: str) -> str:
    return base64.urlsafe_b64encode(text.encode()).decode().rstrip("=")


def ws_frame(opcode: int, payload: bytes) -> bytes:
    """One final, unmasked server frame."""
    size = len(payload)
    if size <= 125:
        head = struct.pack("!BB", 0x80 | opcode, size)
    elif size <= 0xFFFF:
        head = struct.pack("!BBH", 0x80 | opcode, 126, size)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 127, size)
    return head + payload


async def ws_read(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    """The next complete client message as (opcode, payload); masked frames only."""
    message = b""
    first_opcode = 0
    while True:
        b1, b2 = await reader.readexactly(2)
        size = b2 & 0x7F
        if size == 126:
            (size,) = struct.unpack("!H", await reader.readexactly(2))
        elif size == 127:
            (size,) = struct.unpack("!Q", await reader.readexactly(8))
        key = await reader.readexactly(4) if b2 & 0x80 else b"\0\0\0\0"
        data = await reader.readexactly(size)
        data = bytes(byte ^ key[i % 4] for i, byte in enumerate(data))
        opcode = b1 & 0x0F
        if opcode >= 0x8:
            return opcode, data
        first_opcode = first_opcode or opcode
        message += data
        if b1 & 0x80:
            return first_opcode, message


class Gateway:
    """One accepted gateway socket."""

    def __init__(self, writer: asyncio.StreamWriter) -> None:
        self.writer = writer
        self.session_id: str | None = None
        self.token: str | None = None
        self.live = False

    def send(self, payload: dict[str, Any]) -> None:
        self.writer.write(ws_frame(0x1, json.dumps(payload).encode()))

    def close(self, code: int, reason: str = "") -> None:
        try:
            self.writer.write(ws_frame(0x8, struct.pack("!H", code) + reason.encode()))
        finally:
            self.writer.close()

    def abort(self) -> None:
        self.writer.transport.abort()


class FakeDiscord:
    def __init__(
        self,
        bot_id: str = "900000000000000001",
        bot_username: str = "albedo-bot",
        heartbeat_interval_ms: int = 30000,
    ) -> None:
        self.bot: dict[str, Any] = {
            "id": bot_id,
            "username": bot_username,
            "global_name": None,
            "bot": True,
        }
        self.application_id = bot_id
        self.token = f"{b64url(bot_id)}.fake.secret"
        self.heartbeat_interval_ms = heartbeat_interval_ms
        self.users: dict[str, dict[str, Any]] = {bot_id: self.bot}
        # Bot tokens the REST API and gateway accept, and the bot user each logs in as.
        self.token_users: dict[str, dict[str, Any]] = {self.token: self.bot}
        self.guilds: dict[str, dict[str, Any]] = {}
        self.channels: dict[str, dict[str, Any]] = {}
        self.messages: dict[str, list[dict[str, Any]]] = {}
        self.dm_channels: dict[str, str] = {}
        self.sent: list[dict[str, Any]] = []
        self.reactions: list[dict[str, Any]] = []
        self.requests: list[tuple[str, str]] = []
        self.identifies: list[dict[str, Any]] = []
        self.resumes: list[dict[str, Any]] = []
        self.heartbeats = 0
        self.connections = 0
        self.reject_code: int | None = None
        self._init_user_api()
        self._throttle = 0
        self._throttle_after = 0.1
        self._counter = 0
        self._seq = 0
        self._events: list[tuple[int, str, Any]] = []
        self._gateway: Gateway | None = None
        self._sessions: set[str] = set()
        self._loop = asyncio.new_event_loop()
        self._ready = threading.Event()
        self._server: asyncio.base_events.Server | None = None
        self.port = 0
        self._thread = threading.Thread(target=self._run, daemon=True)
        self._thread.start()
        self._ready.wait(10)

    # -- lifecycle ------------------------------------------------------

    def _run(self) -> None:
        asyncio.set_event_loop(self._loop)
        self._server = self._loop.run_until_complete(
            asyncio.start_server(self._accept, "127.0.0.1", 0)
        )
        self.port = self._server.sockets[0].getsockname()[1]
        self._ready.set()
        self._loop.run_forever()

    @property
    def api_url(self) -> str:
        return f"http://127.0.0.1:{self.port}/api/v10"

    @property
    def gateway_url(self) -> str:
        return f"ws://127.0.0.1:{self.port}"

    def stop(self) -> None:
        if not self._loop.is_running():
            return

        async def shutdown() -> None:
            if self._gateway:
                self._gateway.abort()
            if self._server:
                self._server.close()

        asyncio.run_coroutine_threadsafe(shutdown(), self._loop).result(10)
        self._loop.call_soon_threadsafe(self._loop.stop)
        self._thread.join(10)

    def __enter__(self) -> FakeDiscord:
        return self

    def __exit__(self, *_: object) -> None:
        self.stop()

    def _call(self, fn: Callable[[], Any]) -> Any:
        """Run `fn` on the server loop and return its result."""

        async def run() -> Any:
            return fn()

        return asyncio.run_coroutine_threadsafe(run(), self._loop).result(10)

    def _next_id(self) -> str:
        self._counter += 1
        return str(SNOWFLAKE_BASE + self._counter)

    # -- seeding and posting --------------------------------------------

    def add_user(
        self,
        user_id: str,
        username: str,
        global_name: str | None = None,
        bot: bool = False,
    ) -> dict[str, Any]:
        user = {
            "id": user_id,
            "username": username,
            "global_name": global_name,
            "bot": bot,
        }
        self._call(lambda: self.users.setdefault(user_id, user))
        return user

    def add_guild(
        self,
        guild_id: str,
        name: str,
        channels: list[dict[str, Any]] | None = None,
        threads: list[dict[str, Any]] | None = None,
    ) -> None:
        """Seed a guild; a live socket is sent GUILD_CREATE."""

        def add() -> None:
            self.guilds[guild_id] = {"id": guild_id, "name": name}
            for position, channel in enumerate(channels or []):
                self._store_channel(guild_id, channel, position)
            for thread in threads or []:
                self._store_channel(guild_id, {"type": 11, **thread}, 0)
            if self._live():
                self._dispatch("GUILD_CREATE", self._guild_payload(guild_id))

        self._call(add)

    def add_channel(self, guild_id: str, channel: dict[str, Any]) -> None:
        """Add a channel or thread after connect (CHANNEL_CREATE / THREAD_CREATE)."""

        def add() -> None:
            stored = self._store_channel(guild_id, channel, 0)
            name = (
                "THREAD_CREATE" if stored["type"] in (10, 11, 12) else "CHANNEL_CREATE"
            )
            self._dispatch(name, stored)

        self._call(add)

    def _store_channel(
        self, guild_id: str, channel: dict[str, Any], position: int
    ) -> dict[str, Any]:
        stored = {
            "type": 0,
            "parent_id": None,
            "position": position,
            **channel,
            "id": str(channel["id"]),
            "guild_id": guild_id,
        }
        self.channels[stored["id"]] = stored
        self.messages.setdefault(stored["id"], [])
        return stored

    def _guild_payload(self, guild_id: str) -> dict[str, Any]:
        mine = [c for c in self.channels.values() if c.get("guild_id") == guild_id]
        return {
            **self.guilds[guild_id],
            "channels": [c for c in mine if c["type"] not in (10, 11, 12)],
            "threads": [c for c in mine if c["type"] in (10, 11, 12)],
        }

    def dm_channel(self, user_id: str) -> str:
        """The DM channel id between the bot and `user_id`, created if needed."""

        return self._call(lambda: str(self._open_dm(user_id)["id"]))

    def post(
        self,
        channel_id: str,
        content: str,
        author: dict[str, Any] | None = None,
        guild_id: str | None = None,
        mentions: list[Any] | None = None,
        reply_to: str | None = None,
        attachments: list[dict[str, Any]] | None = None,
        nick: str | None = None,
    ) -> str:
        """Store a message in the channel's history and push MESSAGE_CREATE; returns its id."""
        author = author or {"id": "100000000000000001", "username": "alice"}

        def create() -> str:
            user = {
                "global_name": None,
                "bot": False,
                **self.users.get(str(author["id"]), {}),
                **author,
            }
            self.users[str(user["id"])] = user
            return self._add_message(
                channel_id,
                content,
                user,
                guild_id,
                mentions,
                reply_to,
                attachments,
                nick,
            )

        return self._call(create)

    def _add_message(
        self,
        channel_id: str,
        content: str,
        author: dict[str, Any],
        guild_id: str | None,
        mentions: list[Any] | None,
        reply_to: str | None,
        attachments: list[dict[str, Any]] | None,
        nick: str | None,
        extra: dict[str, Any] | None = None,
    ) -> str:
        if guild_id is None:
            guild_id = (self.channels.get(channel_id) or {}).get("guild_id")
        resolved = [
            m if isinstance(m, dict) else self.users.get(str(m), {"id": str(m)})
            for m in mentions or []
        ]
        message: dict[str, Any] = {
            "id": self._next_id(),
            "channel_id": channel_id,
            "content": content,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S.000000+00:00", time.gmtime()),
            "author": author,
            "mentions": resolved,
            "attachments": attachments or [],
            **(extra or {}),
        }
        if reply_to:
            message["message_reference"] = {
                "message_id": reply_to,
                "channel_id": channel_id,
            }
        self.messages.setdefault(channel_id, []).append(message)
        event = dict(message)
        if guild_id:
            event["guild_id"] = guild_id
            event["member"] = {"nick": nick}
        self._dispatch("MESSAGE_CREATE", event)
        return message["id"]

    # -- gateway control ------------------------------------------------

    def _live(self) -> bool:
        return self._gateway is not None and self._gateway.live

    def _dispatch(self, name: str, data: Any) -> None:
        self._seq += 1
        self._events.append((self._seq, name, data))
        if self._live() and self._gateway:
            self._gateway.send({"op": 0, "t": name, "s": self._seq, "d": data})

    def close_socket(self, code: int = 4000, reason: str = "") -> None:
        """Close the live gateway socket with a close frame (a resumable code by default)."""
        self._call(lambda: self._gateway and self._gateway.close(code, reason))

    def drop_connection(self) -> None:
        """Cut the TCP connection without a close frame."""
        self._call(lambda: self._gateway and self._gateway.abort())

    def send_op(self, op: int, data: Any = None) -> None:
        """Send a raw gateway op, such as 7 (reconnect) or 9 (invalid session)."""
        self._call(lambda: self._gateway and self._gateway.send({"op": op, "d": data}))

    def reject_token(self) -> None:
        """Answer every IDENTIFY with close 4004, and close a live socket."""
        self._reject(4004)

    def reject_intents(self) -> None:
        """Answer every IDENTIFY with close 4014, and close a live socket."""
        self._reject(4014)

    def _reject(self, code: int) -> None:
        def apply() -> None:
            self.reject_code = code
            if self._gateway:
                self._gateway.close(code)

        self._call(apply)

    def throttle(self, count: int = 1, retry_after: float = 0.1) -> None:
        """Answer the next `count` REST requests with 429."""

        def apply() -> None:
            self._throttle = count
            self._throttle_after = retry_after

        self._call(apply)

    # -- waiting --------------------------------------------------------

    def wait_for(
        self,
        predicate: Callable[[], bool],
        timeout: float = 10,
        what: str = "condition",
    ) -> None:
        deadline = time.monotonic() + timeout
        while not predicate():
            if time.monotonic() > deadline:
                raise TimeoutError(f"timed out after {timeout}s waiting for {what}")
            time.sleep(0.02)

    def wait_for_sent(self, count: int, timeout: float = 10) -> list[dict[str, Any]]:
        self.wait_for(
            lambda: len(self.sent) >= count, timeout, f"{count} sent messages"
        )
        return list(self.sent)

    def wait_for_reaction(self, timeout: float = 10) -> list[dict[str, Any]]:
        self.wait_for(lambda: bool(self.reactions), timeout, "a reaction")
        return list(self.reactions)

    def wait_for_gateway(self, timeout: float = 10) -> None:
        """Until a socket has identified or resumed and is receiving events."""
        self.wait_for(self._live, timeout, "a live gateway socket")

    def wait_for_identifies(self, count: int, timeout: float = 10) -> None:
        self.wait_for(lambda: len(self.identifies) >= count, timeout, "IDENTIFY")

    def wait_for_resumes(self, count: int, timeout: float = 10) -> None:
        self.wait_for(lambda: len(self.resumes) >= count, timeout, "RESUME")

    # -- server ---------------------------------------------------------

    async def _accept(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter
    ) -> None:
        try:
            head = await reader.readuntil(b"\r\n\r\n")
            lines = head.decode("latin1").split("\r\n")
            method, target, _ = lines[0].split(" ", 2)
            headers = {}
            for line in lines[1:]:
                if ":" in line:
                    key, value = line.split(":", 1)
                    headers[key.strip().lower()] = value.strip()
            if headers.get("upgrade", "").lower() == "websocket":
                await self._gateway_session(reader, writer, headers)
                return
            body = b""
            if "content-length" in headers:
                body = await reader.readexactly(int(headers["content-length"]))
            if method == "GET" and urllib.parse.urlsplit(target).path == "/app":
                page = self.app_page().encode()
                writer.write(
                    f"HTTP/1.1 200 X\r\nContent-Type: text/html; charset=utf-8\r\n"
                    f"Content-Length: {len(page)}\r\nConnection: close\r\n\r\n".encode()
                    + page
                )
                await writer.drain()
                return
            status, payload = self._rest(method, target, headers, body)
            raw = b"" if payload is None else json.dumps(payload).encode()
            writer.write(
                f"HTTP/1.1 {status} X\r\nContent-Type: application/json\r\n"
                f"Content-Length: {len(raw)}\r\nConnection: close\r\n\r\n".encode()
                + raw
            )
            await writer.drain()
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            writer.close()

    def app_page(self) -> str:
        """The Discord web app as a page: a client environment and a session cookie.

        Browser mode reads the REST base from `GLOBAL_ENV` and signs in with the
        cookie, exactly as a real tab would, so this is what stands in for
        `discord.com` without a browser reaching the network.
        """
        return (
            '<!doctype html><html><head><meta charset="utf-8">'
            "<title>Discord</title><script>"
            "window.GLOBAL_ENV={"
            'PROJECT_ENV:"production",BUILD_NUMBER:"641004",RELEASE_CHANNEL:"stable",'
            f'API_PROTOCOL:"http:",API_ENDPOINT:"//127.0.0.1:{self.port}/api",API_VERSION:9'
            "};"
            f'document.cookie="{self.browser_cookie}={self.browser_session}; path=/";'
            '</script></head><body><div id="app"></div></body></html>'
        )

    async def _gateway_session(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        headers: dict[str, str],
    ) -> None:
        accept = base64.b64encode(
            hashlib.sha1((headers["sec-websocket-key"] + GUID).encode()).digest()
        ).decode()
        writer.write(
            (
                "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
                f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode()
        )
        gateway = Gateway(writer)
        self._gateway = gateway
        self.connections += 1
        gateway.send(
            {"op": 10, "d": {"heartbeat_interval": self.heartbeat_interval_ms}}
        )
        try:
            while True:
                opcode, data = await ws_read(reader)
                if opcode == 0x8:
                    break
                if opcode == 0x9:
                    writer.write(ws_frame(0xA, data))
                if opcode in (0x1, 0x2):
                    self._gateway_message(gateway, json.loads(data))
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            gateway.live = False
            writer.close()

    def _gateway_message(self, gateway: Gateway, payload: dict[str, Any]) -> None:
        op = payload.get("op")
        data: dict[str, Any] = payload.get("d") or {}
        if op == 1:
            self.heartbeats += 1
            gateway.send({"op": 11})
        elif op == 2:
            self.identifies.append(data)
            gateway.token = data.get("token")
            if self.reject_code:
                gateway.close(self.reject_code)
                return
            if gateway.token not in self.token_users:
                gateway.close(4004)
                return
            gateway.session_id = f"session-{len(self.identifies)}"
            self._sessions.add(gateway.session_id)
            self._send_ready(gateway)
        elif op == 6:
            self.resumes.append(data)
            if data.get("session_id") not in self._sessions:
                gateway.send({"op": 9, "d": False})
                return
            gateway.session_id = data["session_id"]
            gateway.live = True
            for seq, name, event in self._events:
                if seq > data["seq"]:
                    gateway.send({"op": 0, "t": name, "s": seq, "d": event})
            self._seq += 1
            gateway.send({"op": 0, "t": "RESUMED", "s": self._seq, "d": {}})

    def _send_ready(self, gateway: Gateway) -> None:
        self._seq += 1
        gateway.send(
            {
                "op": 0,
                "t": "READY",
                "s": self._seq,
                "d": {
                    "v": 10,
                    "user": self.token_users.get(gateway.token or "", self.bot),
                    "session_id": gateway.session_id,
                    "resume_gateway_url": self.gateway_url,
                    "application": {"id": self.application_id},
                    "guilds": [{"id": g, "unavailable": True} for g in self.guilds],
                },
            }
        )
        gateway.live = True
        for guild_id in self.guilds:
            self._dispatch("GUILD_CREATE", self._guild_payload(guild_id))

    # -- REST -----------------------------------------------------------

    def _rest(
        self, method: str, target: str, headers: dict[str, str], body: bytes
    ) -> tuple[int, Any]:
        url = urllib.parse.urlsplit(target)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(url.query).items()}
        path = re.sub(r"^/api/v\d+", "", url.path)
        self.requests.append((method, path))
        authorization = headers.get("authorization", "")
        if not authorization and self._browser_session(headers):
            if not self.signed_in:
                return 401, {"message": "401: Unauthorized", "code": 0}
            if self._throttle > 0:
                self._throttle -= 1
                return 429, {
                    "message": "rate limited",
                    "retry_after": self._throttle_after,
                }
            return self._user_rest(method, path, query, headers, body, browser=True)
        if authorization == self.user_token:
            if self.user_unauthorized:
                return 401, {"message": "401: Unauthorized", "code": 0}
            if self._throttle > 0:
                self._throttle -= 1
                return 429, {
                    "message": "rate limited",
                    "retry_after": self._throttle_after,
                }
            return self._user_rest(method, path, query, headers, body)
        if not authorization.startswith("Bot ") or (
            authorization.removeprefix("Bot ") not in self.token_users
        ):
            return 401, {"message": "401: Unauthorized", "code": 0}
        if self._throttle > 0:
            self._throttle -= 1
            return 429, {"message": "rate limited", "retry_after": self._throttle_after}
        data = json.loads(body) if body else {}
        parts = [urllib.parse.unquote(p) for p in path.strip("/").split("/")]
        if parts == ["gateway", "bot"] and method == "GET":
            return 200, {"url": self.gateway_url, "shards": 1}
        if parts == ["users", "@me", "channels"] and method == "POST":
            return 200, self._open_dm(str(data["recipient_id"]))
        if len(parts) == 2 and parts[0] == "users" and method == "GET":
            user = self.users.get(parts[1])
            if parts[1] == "@me":
                user = self.bot
            return (
                (200, user)
                if user
                else (404, {"message": "Unknown User", "code": 10013})
            )
        if len(parts) >= 2 and parts[0] == "channels":
            channel_id = parts[1]
            if channel_id not in self.channels:
                return 404, {"message": "Unknown Channel", "code": 10003}
            return self._channel_route(method, parts, query, data)
        return 404, {"message": "404: Not Found", "code": 0}

    # -- user-token API (bot provisioning) --------------------------------

    def _init_user_api(self) -> None:
        self.user_token = "user.fake.secret"
        # The human the user token belongs to (GET /users/@me).
        self.account = {
            "id": "100000000000000090",
            "username": "owner",
            "global_name": "Owner",
        }
        self.user_unauthorized = False
        # A signed-in web client: the cookie a Chrome tab carries, and whether
        # that session is still valid. A browser-mode request has no
        # Authorization header, only this cookie.
        self.browser_cookie = "albedo-browser"
        self.browser_session = "browser.fake.secret"
        self.signed_in = True
        self.applications: dict[str, dict[str, Any]] = {}
        self.new_app_flags = 0
        self.user_guilds: list[dict[str, Any]] = []
        self.authorized: list[dict[str, Any]] = []
        self.user_calls: list[dict[str, Any]] = []
        self.mfa_code: str | None = None
        self.mfa_methods: list[Any] = [{"type": "totp"}]
        self.mfa_attempts: list[dict[str, Any]] = []
        self._mfa_ticket = "mfa-ticket"
        self._mfa_tokens: set[str] = set()
        self._captcha: set[tuple[str, str]] = set()

    def require_mfa(
        self, code: str = "123456", methods: list[Any] | None = None
    ) -> None:
        """Sensitive user calls answer 401 / 60003 until /mfa/finish is given `code`."""

        def apply() -> None:
            self.mfa_code = code
            self.mfa_methods = methods or [{"type": "totp"}]

        self._call(apply)

    @property
    def browser_url(self) -> str:
        """The page a browser-mode provisioner opens instead of a login screen."""
        return f"http://127.0.0.1:{self.port}/app"

    def sign_out(self) -> None:
        """Make browser-mode calls answer 401 until `sign_in`."""
        self._call(lambda: setattr(self, "signed_in", False))

    def sign_in(self) -> None:
        self._call(lambda: setattr(self, "signed_in", True))

    def browser_calls(self) -> list[dict[str, Any]]:
        """The user-API calls that arrived from the page rather than a token."""
        return [call for call in self.user_calls if call.get("browser")]

    def require_captcha(self, method: str, path: str) -> None:
        """Answer `method` `path` (e.g. POST /applications) with a captcha challenge."""
        self._call(lambda: self._captcha.add((method, path)))

    def revoke_user_token(self) -> None:
        self._call(lambda: setattr(self, "user_unauthorized", True))

    def add_user_guild(
        self,
        guild_id: str,
        name: str,
        permissions: int = 0,
        owner: bool = False,
        icon: str | None = None,
    ) -> None:
        """A guild listed by GET /users/@me/guilds."""
        guild = {
            "id": guild_id,
            "name": name,
            "icon": icon,
            "owner": owner,
            "permissions": str(permissions),
        }
        self._call(lambda: self.user_guilds.append(guild))

    def add_application(self, name: str, flags: int = 0, bot: bool = True) -> str:
        """An application owned by the user, with a bot user when `bot`."""

        def add() -> str:
            app = self._new_application(name, flags)
            if bot:
                self._botify(app)
            return app["id"]

        return self._call(add)

    def _new_application(self, name: str, flags: int) -> dict[str, Any]:
        app = {"id": self._next_id(), "name": name, "flags": flags}
        self.applications[app["id"]] = app
        return app

    def _botify(self, app: dict[str, Any]) -> None:
        bot_id = self._next_id()
        app["bot"] = {
            "id": bot_id,
            "username": app["name"],
            "global_name": None,
            "bot": True,
        }
        self.users[bot_id] = app["bot"]

    def _mint_bot_token(self, app: dict[str, Any]) -> str:
        token = f"{b64url(app['bot']['id'])}.fake.{self._next_id()}"
        self.token_users[token] = app["bot"]
        return token

    def _browser_session(self, headers: dict[str, str]) -> bool:
        """Whether the request carries the signed-in web client's cookie."""
        wanted = f"{self.browser_cookie}={self.browser_session}"
        cookies = [part.strip() for part in headers.get("cookie", "").split(";")]
        return wanted in cookies

    def _user_rest(
        self,
        method: str,
        path: str,
        query: dict[str, str],
        headers: dict[str, str],
        body: bytes,
        browser: bool = False,
    ) -> tuple[int, Any]:
        data = json.loads(body) if body else {}
        mfa_header = headers.get("x-discord-mfa-authorization")
        self.user_calls.append(
            {
                "method": method,
                "path": path,
                "query": query,
                "body": data,
                "mfa": mfa_header,
                "browser": browser,
            }
        )
        if (method, path) in self._captcha:
            return 400, {
                "captcha_key": ["captcha-required"],
                "captcha_service": "hcaptcha",
            }
        parts = path.strip("/").split("/")
        sensitive = (
            parts[-2:] == ["bot", "reset"]
            or parts[-1:] == ["delete"]
            or path == "/oauth2/authorize"
        )
        if sensitive and self.mfa_code and mfa_header not in self._mfa_tokens:
            return 401, {
                "message": "Two factor is required for this operation",
                "code": 60003,
                "mfa": {"ticket": self._mfa_ticket, "methods": self.mfa_methods},
            }
        if (method, path) == ("POST", "/mfa/finish"):
            return self._mfa_finish(data)
        if (method, path) == ("GET", "/users/@me"):
            return 200, self.account
        if (method, path) == ("GET", "/users/@me/guilds"):
            return 200, self.user_guilds
        if (method, path) == ("POST", "/oauth2/authorize"):
            return self._authorize(query, data)
        if (method, path) == ("GET", "/applications"):
            return 200, list(self.applications.values())
        if (method, path) == ("POST", "/applications"):
            if "discord" in str(data.get("name", "")).lower():
                return 400, {
                    "message": "Invalid Form Body",
                    "code": 50035,
                    "errors": {
                        "_errors": [
                            {
                                "code": "APPLICATION_NAME_INVALID_CONTAINS",
                                "message": 'Application name cannot contain "discord"',
                            }
                        ]
                    },
                }
            app = self._new_application(data["name"], self.new_app_flags)
            return 200, app
        if parts[0] == "applications" and len(parts) >= 2:
            app = self.applications.get(parts[1])
            if app is None:
                return 404, {"message": "Unknown Application", "code": 10002}
            return self._application_route(method, parts[2:], app, data)
        return 404, {"message": "404: Not Found", "code": 0}

    def _mfa_finish(self, data: dict[str, Any]) -> tuple[int, Any]:
        self.mfa_attempts.append(data)
        if data.get("ticket") != self._mfa_ticket or data.get("data") != self.mfa_code:
            return 400, {"message": "Invalid two-factor code", "code": 60008}
        token = f"mfa-token-{len(self._mfa_tokens) + 1}"
        self._mfa_tokens.add(token)
        return 200, {"token": token}

    def _authorize(
        self, query: dict[str, str], data: dict[str, Any]
    ) -> tuple[int, Any]:
        if query.get("client_id") not in self.applications:
            return 404, {"message": "Unknown Application", "code": 10002}
        self.authorized.append({"query": query, "body": data})
        return 200, {"location": "https://discord.com/oauth2/authorized"}

    def _application_route(
        self, method: str, rest: list[str], app: dict[str, Any], data: dict[str, Any]
    ) -> tuple[int, Any]:
        if (method, rest) == ("GET", []):
            return 200, app
        if (method, rest) == ("PATCH", []):
            app.update({k: v for k, v in data.items() if k in ("flags", "name")})
            return 200, app
        if (method, rest) == ("POST", ["bot"]):
            if "bot" not in app:
                self._botify(app)
            return 200, {}
        if (method, rest) == ("PATCH", ["bot"]) and "bot" in app:
            app["bot"].update({k: v for k, v in data.items() if k == "avatar"})
            return 200, app["bot"]
        if (method, rest) == ("POST", ["bot", "reset"]) and "bot" in app:
            return 200, {"token": self._mint_bot_token(app)}
        if (method, rest) == ("POST", ["delete"]):
            del self.applications[app["id"]]
            return 204, None
        return 404, {"message": "404: Not Found", "code": 0}

    def _open_dm(self, user_id: str) -> dict[str, Any]:
        if user_id not in self.dm_channels:
            channel_id = self._next_id()
            self.dm_channels[user_id] = channel_id
            self.channels[channel_id] = {
                "id": channel_id,
                "type": 1,
                "recipients": [self.users.get(user_id, {"id": user_id})],
            }
            self.messages[channel_id] = []
        return self.channels[self.dm_channels[user_id]]

    def _channel_route(
        self, method: str, parts: list[str], query: dict[str, str], data: dict[str, Any]
    ) -> tuple[int, Any]:
        channel_id = parts[1]
        channel = self.channels[channel_id]
        if len(parts) == 2 and method == "GET":
            return 200, channel
        if parts[2:] == ["messages"] and method == "POST":
            reference = data.get("message_reference") or {}
            sent_id = self._add_message(
                channel_id,
                data.get("content", ""),
                self.bot,
                None,
                None,
                reference.get("message_id"),
                None,
                None,
            )
            message = self._find(channel_id, sent_id)
            self.sent.append(
                {
                    "channel_id": channel_id,
                    "id": sent_id,
                    "content": data.get("content", ""),
                    "message_reference": data.get("message_reference"),
                    "allowed_mentions": data.get("allowed_mentions"),
                }
            )
            return 200, message
        if parts[2:] == ["messages"] and method == "GET":
            return 200, self._history(channel_id, query)
        if len(parts) == 7 and parts[2] == "messages" and parts[4] == "reactions":
            self.reactions.append(
                {"channel_id": channel_id, "message_id": parts[3], "emoji": parts[5]}
            )
            return 204, None
        return 404, {"message": "404: Not Found", "code": 0}

    def _find(self, channel_id: str, message_id: str) -> dict[str, Any]:
        return next(m for m in self.messages[channel_id] if m["id"] == message_id)

    def _history(self, channel_id: str, query: dict[str, str]) -> list[dict[str, Any]]:
        """Newest first, as Discord returns it; REST messages carry no guild_id."""
        everything = self.messages[channel_id]
        limit = int(query.get("limit", 50))
        if "before" in query:
            chosen = [m for m in everything if int(m["id"]) < int(query["before"])][
                -limit:
            ]
        elif "after" in query:
            chosen = [m for m in everything if int(m["id"]) > int(query["after"])][
                :limit
            ]
        else:
            chosen = everything[-limit:]
        return list(reversed(chosen))
