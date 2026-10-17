"""One-shot Discord bot provisioning, against Discord's ToS (opt-in).

Creates a bot application without the developer portal, mirroring the calls in
dolfies/discord.py-self (discord/http.py): POST /applications, POST
/applications/{id}/bot, PATCH /applications/{id}, POST /applications/{id}/bot/reset,
GET /applications, POST /applications/{id}/delete, GET /users/@me/guilds and
POST /oauth2/authorize. JSON lines on stdin and stdout, like albedo_discord.py.

Two ways to reach Discord, both writing the same lines:

  ALBEDO_DISCORD_USER_TOKEN   the human's user token, called from this process
                              with a browser User-Agent and no other client
                              headers, which is why Discord may answer with a
                              captcha;
  ALBEDO_DISCORD_BROWSER=1    browser mode: albedo_discord_browser.py opens
                              Chrome on the web app and runs the same calls in
                              that page, with the client's own fingerprint,
                              cookies and headers. Nothing is pasted; the human
                              signs in in the window, and Discord's captcha, if
                              it comes, is answered there too.

Environment:
  ALBEDO_DISCORD_API              REST base; default https://discord.com/api/v9
                                  (browser mode reads the page's own base instead)
  ALBEDO_DISCORD_LOGIN_TIMEOUT    browser mode: seconds to wait for a sign-in, 300

stdin: one request line, then (only after an "mfa" line) {"code": "123456"}.
  {"op":"create","name":s,"avatar":data-url|null}
  {"op":"me"}  (the user's id, username and global_name)
  {"op":"guilds"}
  {"op":"authorize","application_id":s,"guild_id":s}
  {"op":"apps"}
  {"op":"delete","application_id":s}
stdout: {"type":"progress","step":"login"|"create"|"bot"|"intent"|"token"},
  {"type":"mfa","methods":[...],"error"?:s}, and one final
  {"type":"result","ok":true,"result":...} or
  {"type":"result","ok":false,"error":s,"code":"captcha"|"mfa_failed"|"unauthorized"|
   "rate_limited"|"http"} followed by exit 1.

The only secret ever written to stdout is the new bot token in the create result.
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any

DEFAULT_API = "https://discord.com/api/v9"
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36"
)
MESSAGE_CONTENT_FLAG = 1 << 19
ADMINISTRATOR = 1 << 3
MANAGE_GUILD = 1 << 5
BOT_PERMISSIONS = "274878024768"
MFA_ATTEMPTS = 3
MAX_RETRY_AFTER = 15.0
MFA_REQUIRED = 60003
DEFAULT_LOGIN_TIMEOUT = 300.0
LOGIN_POLL = 2.0


class Failure(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def emit(line: dict[str, Any]) -> None:
    print(json.dumps(line), flush=True)


def read_line() -> dict[str, Any] | None:
    """The next JSON object on stdin, or None at EOF."""
    raw = sys.stdin.readline()
    if not raw:
        return None
    try:
        value = json.loads(raw)
    except ValueError:
        raise Failure("http", "invalid request line") from None
    if not isinstance(value, dict):
        raise Failure("http", "request must be a JSON object")
    return value


def field_errors(data: dict[str, Any]) -> list[str]:
    """The messages in a 50035 "Invalid Form Body" answer's nested `errors`."""
    found: list[str] = []

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            for item in node.get("_errors") or []:
                if isinstance(item, dict) and item.get("message"):
                    found.append(str(item["message"]))
            for key, value in node.items():
                if key != "_errors":
                    walk(value)

    walk(data.get("errors"))
    return found


def failure_text(status: int, data: dict[str, Any]) -> str:
    detail = "; ".join(field_errors(data)) or str(data.get("message", ""))
    return f"HTTP {status}: {detail}"


def method_names(methods: Any) -> list[str]:
    names = []
    for method in methods if isinstance(methods, list) else []:
        name = method.get("type") if isinstance(method, dict) else method
        if isinstance(name, str):
            names.append(name)
    return names


class Token:
    """Discord as this process, with the human's token."""

    rejected = "the user token was rejected"

    def __init__(self, token: str, api: str) -> None:
        self.token = token
        self.api = api.rstrip("/")

    async def raw(
        self, method: str, path: str, body: Any, extra: dict[str, str]
    ) -> tuple[int, Any]:
        headers = {
            "Authorization": self.token,
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
            **extra,
        }
        data = None
        if body is not None:
            data = json.dumps(body).encode()
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            self.api + path, data=data, headers=headers, method=method.upper()
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                status, payload = response.status, response.read()
        except urllib.error.HTTPError as error:
            status, payload = error.code, error.read()
        except OSError as error:
            raise Failure("http", f"network error: {error}") from None
        try:
            return status, json.loads(payload) if payload else None
        except ValueError:
            return status, None

    async def sign_in(self) -> None:
        """Nothing to do: the token is the sign-in."""
        return None

    async def close(self) -> None:
        return None


class Discord:
    """The provisioning calls, over either transport."""

    def __init__(self, transport: Any) -> None:
        self.transport = transport
        self.mfa_token: str | None = None

    async def call(self, method: str, path: str, body: Any = None) -> Any:
        """One API call; satisfies MFA and honours short rate limits."""
        throttled = 0
        while True:
            extra = {}
            if self.mfa_token:
                extra["X-Discord-MFA-Authorization"] = self.mfa_token
            status, payload = await self.transport.raw(method, path, body, extra)
            data = payload if isinstance(payload, dict) else {}
            if status < 300:
                return payload
            if status == 429:
                wait = float(data.get("retry_after") or 1)
                throttled += 1
                if throttled > 2 or wait > MAX_RETRY_AFTER:
                    raise Failure("rate_limited", f"rate limited, retry in {wait:g}s")
                await asyncio.sleep(wait)
            elif status == 401 and data.get("code") == MFA_REQUIRED:
                mfa = data.get("mfa") or {}
                self.mfa_token = await self.satisfy_mfa(
                    mfa.get("ticket"), mfa.get("methods")
                )
            elif status == 401:
                raise Failure("unauthorized", self.transport.rejected)
            elif status == 400 and "captcha_key" in data:
                raise Failure("captcha", "Discord asks for a captcha")
            else:
                raise Failure("http", failure_text(status, data))

    async def satisfy_mfa(self, ticket: Any, methods: Any) -> str:
        """Prompt for TOTP codes (three tries) and trade the ticket for an MFA token."""
        names = method_names(methods) or ["totp"]
        if not isinstance(ticket, str) or not {"totp", "backup"} & set(names):
            raise Failure("mfa_failed", "no supported MFA method (authenticator app)")
        error = None
        for _ in range(MFA_ATTEMPTS):
            prompt: dict[str, Any] = {"type": "mfa", "methods": names}
            if error:
                prompt["error"] = error
            emit(prompt)
            reply = read_line()
            if reply is None:
                raise Failure("mfa_failed", "stdin closed while waiting for MFA code")
            code = str(reply.get("code", "")).strip()
            kind = "totp" if len(code) == 6 else "backup"
            status, payload = await self.transport.raw(
                "post",
                "/mfa/finish",
                {"ticket": ticket, "mfa_type": kind, "data": code},
                {},
            )
            data = payload if isinstance(payload, dict) else {}
            if status < 300 and isinstance(data.get("token"), str):
                return data["token"]
            if status == 429:
                raise Failure("rate_limited", "rate limited while verifying MFA")
            if status == 401 and data.get("code") != 60008:
                raise Failure("unauthorized", self.transport.rejected)
            error = str(data.get("message") or "invalid code")
        raise Failure("mfa_failed", f"MFA failed after {MFA_ATTEMPTS} attempts")


async def create(client: Discord, request: dict[str, Any]) -> dict[str, Any]:
    name = request.get("name")
    if not isinstance(name, str) or not name.strip():
        raise Failure("http", "name is required")
    emit({"type": "progress", "step": "create"})
    app = await client.call("post", "/applications", {"name": name})
    app_id = str(app["id"])
    path = f"/applications/{app_id}"

    emit({"type": "progress", "step": "bot"})
    if not app.get("bot"):
        await client.call("post", f"{path}/bot", {})
    avatar = request.get("avatar")
    if avatar:
        await client.call("patch", f"{path}/bot", {"avatar": avatar})
    app = await client.call("get", path)
    bot = app.get("bot") or {}
    if not bot.get("id"):
        raise Failure("http", "the application has no bot user")

    emit({"type": "progress", "step": "intent"})
    flags = int(app.get("flags") or 0) | MESSAGE_CONTENT_FLAG
    await client.call("patch", path, {"flags": flags})

    emit({"type": "progress", "step": "token"})
    token = (await client.call("post", f"{path}/bot/reset")).get("token")
    if not isinstance(token, str):
        raise Failure("http", "Discord returned no bot token")
    return {
        "application_id": app_id,
        "name": app.get("name", name),
        "bot_user_id": str(bot["id"]),
        "username": bot.get("username"),
        "token": token,
    }


async def me(client: Discord, _: dict[str, Any]) -> dict[str, Any]:
    user = await client.call("get", "/users/@me")
    return {
        "id": str(user["id"]),
        "username": user.get("username"),
        "global_name": user.get("global_name"),
    }


def can_add_bots(guild: dict[str, Any]) -> bool:
    if guild.get("owner"):
        return True
    return bool(int(guild.get("permissions") or 0) & (ADMINISTRATOR | MANAGE_GUILD))


async def guilds(client: Discord, _: dict[str, Any]) -> list[dict[str, Any]]:
    found = await client.call("get", "/users/@me/guilds")
    return [
        {"id": str(g["id"]), "name": g.get("name"), "icon": g.get("icon")}
        for g in found
        if can_add_bots(g)
    ]


async def authorize(client: Discord, request: dict[str, Any]) -> None:
    app_id, guild_id = request.get("application_id"), request.get("guild_id")
    if not app_id or not guild_id:
        raise Failure("http", "application_id and guild_id are required")
    query = urllib.parse.urlencode(
        {"client_id": app_id, "scope": "bot", "permissions": BOT_PERMISSIONS}
    )
    await client.call(
        "post",
        f"/oauth2/authorize?{query}",
        {
            "guild_id": str(guild_id),
            "permissions": BOT_PERMISSIONS,
            "authorize": True,
        },
    )


async def apps(client: Discord, _: dict[str, Any]) -> list[dict[str, Any]]:
    found = await client.call("get", "/applications?with_team_applications=false")
    return [
        {"id": str(a["id"]), "name": a.get("name"), "bot_user_id": str(a["bot"]["id"])}
        for a in found
        if a.get("bot")
    ]


async def delete(client: Discord, request: dict[str, Any]) -> None:
    app_id = request.get("application_id")
    if not app_id:
        raise Failure("http", "application_id is required")
    await client.call("post", f"/applications/{app_id}/delete")


OPS = {
    "me": me,
    "create": create,
    "guilds": guilds,
    "authorize": authorize,
    "apps": apps,
    "delete": delete,
}


async def sign_in(transport: Any) -> None:
    """Browser mode: wait for a human to sign in in the window we opened."""
    if await transport.me() < 300:
        return
    emit({"type": "progress", "step": "login"})
    timeout = float(
        os.environ.get("ALBEDO_DISCORD_LOGIN_TIMEOUT") or DEFAULT_LOGIN_TIMEOUT
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        await asyncio.sleep(LOGIN_POLL)
        if await transport.me() < 300:
            return
    raise Failure(
        "unauthorized",
        "nobody signed in to Discord in the browser window; the developer portal can still make the bot",
    )


async def transport() -> Any:
    """The transport this run was asked for, signed in and ready."""
    api = os.environ.get("ALBEDO_DISCORD_API")
    if os.environ.get("ALBEDO_DISCORD_BROWSER") == "1":
        from albedo_discord_browser import Browser, BrowserUnavailable

        window = Browser(api)
        try:
            await window.open()
            await sign_in(window)
        except BrowserUnavailable as error:
            await window.close()
            raise Failure("http", str(error)) from None
        except Failure:
            await window.close()
            raise
        return window
    token = os.environ.get("ALBEDO_DISCORD_USER_TOKEN")
    if not token:
        raise Failure("unauthorized", "ALBEDO_DISCORD_USER_TOKEN is not set")
    return Token(token, api or DEFAULT_API)


async def run() -> None:
    request = read_line()
    if request is None:
        raise Failure("http", "no request on stdin")
    handler = OPS.get(str(request.get("op")))
    if handler is None:
        raise Failure("http", f"unknown op {request.get('op')!r}")
    where = await transport()
    try:
        result = await handler(Discord(where), request)
    finally:
        await where.close()
    emit({"type": "result", "ok": True, "result": result})


def main() -> None:
    try:
        asyncio.run(run())
    except Failure as failure:
        emit(
            {
                "type": "result",
                "ok": False,
                "error": failure.message,
                "code": failure.code,
            }
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
