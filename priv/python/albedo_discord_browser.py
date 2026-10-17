"""Discord REST calls made in a real Chrome tab, for bot provisioning.

Discord scores a request by its TLS and HTTP fingerprint, its cookies and the
headers its own client sends. A request from urllib looks like nothing Discord
ships, which is what its captcha tends to react to. This module keeps a Chrome
window with a profile of its own open on Discord's web app and runs every
request inside that page instead: the fingerprint and the cookies are the real
client's, and the headers are rebuilt from the page's own `GLOBAL_ENV` and
`navigator`, so they carry the client's build number and release channel.

The page is the transport; it knows nothing about applications or bots. `raw()`
answers `(status, data)` like an HTTP client would, and 0 means the request
never left the page. Signing in, a captcha, and two-factor are answered by the
human in that window, not here.

Environment:
  ALBEDO_DISCORD_API              REST base; default read from the page
  ALBEDO_DISCORD_APP_URL          page to run in, default https://discord.com/channels/@me
  ALBEDO_DISCORD_BROWSER_PROFILE  profile directory, default <albedo home>/discord-browser
  ALBEDO_DISCORD_BROWSER_HEADLESS 1 to hide the window (tests; signing in needs it)
"""

from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
from typing import Any

DEFAULT_APP_URL = "https://discord.com/channels/@me"


class BrowserUnavailable(Exception):
    """Chrome, the page, or the call could not run."""


# Installed before every call: signing in reloads the document, which drops it,
# and reinstalling is cheaper than watching for navigations.
_SCRIPT = r"""
window.__albedoDiscord || (window.__albedoDiscord = (() => {
  const b64 = (text) => {
    const bytes = new TextEncoder().encode(text);
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
  };
  const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : String(Math.random()).slice(2));
  const superProperties = () => {
    const agent = navigator.userAgent;
    const env = window.GLOBAL_ENV || {};
    const chrome = /Chrome\/([0-9.]+)/.exec(agent);
    const mac = /Mac OS X ([0-9_]+)/.exec(agent);
    const windows = /Windows NT ([0-9.]+)/.exec(agent);
    const build = Number(env.BUILD_NUMBER);
    return b64(JSON.stringify({
      os: /Macintosh/.test(agent) ? "Mac OS X" : (/Windows/.test(agent) ? "Windows" : "Linux"),
      browser: "Chrome",
      device: "",
      device_model_name: "",
      system_locale: navigator.language || "en-US",
      has_client_mods: false,
      browser_user_agent: agent,
      browser_version: chrome ? chrome[1] : "",
      os_version: mac ? mac[1].replace(/_/g, ".") : (windows ? windows[1] : ""),
      referrer: document.referrer || "",
      referring_domain: "",
      referrer_current: "",
      referring_domain_current: "",
      release_channel: env.RELEASE_CHANNEL || "stable",
      client_build_number: Number.isFinite(build) ? build : 0,
      client_event_source: null,
      client_launch_id: uuid(),
      launch_signature: uuid(),
      client_app_state: document.hasFocus() ? "focused" : "unfocused"
    }));
  };
  const apiBase = () => {
    const env = window.GLOBAL_ENV || {};
    if (!env.API_ENDPOINT) return null;
    const host = (env.API_ENDPOINT.indexOf("//") === 0 ? (env.API_PROTOCOL || location.protocol) + env.API_ENDPOINT : env.API_ENDPOINT);
    return host.replace(/\/$/, "") + "/v" + (env.API_VERSION || 9);
  };
  const call = async (method, url, body, extra) => {
    const headers = Object.assign({
      "Content-Type": "application/json",
      "X-Discord-Locale": navigator.language || "en-US",
      "X-Discord-Timezone": Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC",
      "X-Debug-Options": "bugReporterEnabled",
      "X-Super-Properties": superProperties()
    }, extra || {});
    const options = {
      method: method === "del" ? "DELETE" : method.toUpperCase(),
      headers: headers,
      credentials: "include"
    };
    if (body !== undefined && body !== null && options.method !== "GET") {
      options.body = JSON.stringify(body);
    }
    try {
      const answer = await fetch(url, options);
      const text = await answer.text();
      let data = null;
      if (text) {
        try { data = JSON.parse(text); } catch (error) { data = { message: text.slice(0, 300) }; }
      }
      return { status: answer.status, data: data };
    } catch (error) {
      return { status: 0, data: { message: String((error && error.message) || error) } };
    }
  };
  return { call: call, apiBase: apiBase, superProperties: superProperties };
})());
"""


def call_expression(
    method: str, url: str, body: Any, extra: dict[str, str] | None
) -> str:
    """JavaScript that installs the transport if needed and makes one call."""
    args = [json.dumps(method), json.dumps(url)]
    args.append("undefined" if body is None else json.dumps(body))
    args.append(json.dumps(extra or {}))
    return (
        "(() => {"
        + _SCRIPT
        + " return window.__albedoDiscord.call("
        + ", ".join(args)
        + "); })()"
    )


def wait_expression(seconds: float) -> str:
    """JavaScript that waits for the page's client environment to exist."""
    return (
        "(() => {"
        + _SCRIPT
        + " const until = Date.now() + "
        + str(int(seconds * 1000))
        + ";"
        + " const tick = () => { const base = window.__albedoDiscord.apiBase();"
        + " if (base) return Promise.resolve(base);"
        + " if (Date.now() > until) return Promise.resolve(null);"
        + " return new Promise((done) => setTimeout(done, 250)).then(tick); };"
        + " return tick(); })()"
    )


def profile_path() -> Path:
    override = os.environ.get("ALBEDO_DISCORD_BROWSER_PROFILE")
    if override:
        return Path(override).expanduser()
    home = os.environ.get("ALBEDO_HOME") or "~/.albedo"
    return Path(home).expanduser() / "discord-browser"


class Browser:
    """A Chrome window with a Discord tab, as a request transport."""

    rejected = "the Discord window is not signed in"

    def __init__(
        self,
        api: str | None = None,
        app_url: str | None = None,
        *,
        headless: bool | None = None,
        timeout: float = 120,
    ) -> None:
        self.api = (api or "").rstrip("/")
        self.app_url = (
            app_url or os.environ.get("ALBEDO_DISCORD_APP_URL") or DEFAULT_APP_URL
        )
        if headless is None:
            headless = os.environ.get("ALBEDO_DISCORD_BROWSER_HEADLESS") == "1"
        self.headless = headless
        self.timeout = timeout
        self._browser: Any = None
        self._page: Any = None

    async def open(self) -> None:
        """Start Chrome, attach to the one already using the profile, and open the app."""
        from albedo_plugins.browser import launch, session
        from albedo_plugins.browser.errors import BrowserError, LaunchError

        profile = profile_path()
        try:
            self._browser = await launch.spawn(headless=self.headless, profile=profile)
        except LaunchError as error:
            if error.details.get("reason") != "profile_in_use":
                raise BrowserUnavailable(_launch_message(error)) from None
            try:
                self._browser = await session.connect(await self._endpoint(profile))
            except BrowserError as attached:
                raise BrowserUnavailable(
                    f"the Discord window could not be reached: {attached}"
                ) from None
        try:
            self._page = await self._browser.new_page(self.app_url)
        except BrowserError as error:
            raise BrowserUnavailable(
                f"the Discord page did not open: {error}"
            ) from None
        if not self.api:
            self.api = await self._page_base()

    async def _page_base(self) -> str:
        """The REST base the loaded page uses, from its own `GLOBAL_ENV`."""
        try:
            base = await self._page.evaluate(wait_expression(20), timeout=self.timeout)
        except Exception as error:
            raise BrowserUnavailable(
                f"the Discord page did not load: {error}"
            ) from None
        if not isinstance(base, str) or not base:
            raise BrowserUnavailable(f"{self.app_url} did not report a Discord client")
        return base.rstrip("/")

    async def _endpoint(self, profile: Path) -> str:
        """The CDP endpoint of the Chrome already holding the profile."""
        active = profile / "DevToolsActivePort"
        for _ in range(20):
            try:
                port = active.read_text(encoding="ascii").splitlines()[0].strip()
            except (OSError, IndexError):
                port = ""
            if port.isdigit():
                return f"http://127.0.0.1:{port}"
            await asyncio.sleep(0.25)
        raise BrowserUnavailable(
            f"{profile} is held by a Chrome that is not answering over CDP;"
            " close that window and try again"
        )

    async def raw(
        self, method: str, path: str, body: Any, extra: dict[str, str] | None = None
    ) -> tuple[int, Any]:
        """One call in the page: `(status, data)`, 0 meaning it never left the page."""
        if self._page is None:
            raise BrowserUnavailable("the Discord page is not open")
        try:
            answer = await self._page.evaluate(
                call_expression(method, self.api + path, body, extra),
                timeout=self.timeout,
            )
        except Exception as error:  # a JavaScript error, a closed tab, a lost browser
            raise BrowserUnavailable(f"the Discord page failed: {error}") from None
        if not isinstance(answer, dict) or not isinstance(answer.get("status"), int):
            raise BrowserUnavailable(f"the Discord page answered {answer!r}")
        return answer["status"], answer.get("data")

    async def me(self) -> int:
        """`GET /users/@me`: below 300 means the window is signed in."""
        status, _ = await self.raw("get", "/users/@me", None)
        return status

    async def close(self) -> None:
        """Close what we opened; a Chrome we merely attached to is left alone."""
        browser, self._browser, self._page = self._browser, None, None
        if browser is None:
            return
        try:
            await browser.close()
        except Exception:
            pass


def _launch_message(error: Any) -> str:
    reason = error.details.get("reason")
    if reason == "executable_not_found":
        return "Chrome or Chromium was not found; install one, or paste a user token instead"
    if reason == "unsafe_profile":
        return f"the profile at {error.details.get('profile')} was not created by albedo; remove it"
    return f"Chrome did not start: {error}"
