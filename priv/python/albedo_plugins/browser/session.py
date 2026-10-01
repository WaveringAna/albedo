"""Browser ownership, target routing and explicit event scopes."""

from __future__ import annotations

from typing import SupportsIndex

import asyncio
import os
from pathlib import Path
from typing import Any, TYPE_CHECKING
from urllib.parse import urlsplit, urlunsplit

import json
import urllib.request

from .errors import BrowserError, ConnectionLost, UnsupportedOperation
from .events import EventScope
from .page import Page
from .transport import CDPSession, Connection, JSON, positive


if TYPE_CHECKING:
    from .launch import OwnedChrome


class Browser:
    def __init__(
        self,
        connection: Connection,
        endpoint: str,
        *,
        headers: dict[str, str] | None = None,
    ) -> None:
        self._connection = connection
        self.endpoint = endpoint
        self._headers = dict(headers) if headers else None
        self._lifecycle_lock = asyncio.Lock()
        self.version: JSON = {}
        self.cdp = CDPSession(connection)
        self._pages: dict[str, Page] = {}
        self._routes: dict[str, Page] = {}
        self._contexts: set[str] = set()
        self._owner: OwnedChrome | None = None
        self._close_task: asyncio.Task[None] | None = None
        connection.on_event = self._on_event

    def _on_event(self, method: str, params: JSON, session_id: str | None) -> None:
        page = self._routes.get(session_id)
        if page is not None and session_id is not None:
            page._on_event(method, params, session_id)
        if method == "Target.detachedFromTarget":
            sid = params.get("sessionId")
            self._connection.detach_session(sid)
            owner = self._routes.get(sid)
            if owner is not None and isinstance(sid, str):
                owner._detached(sid)
                self._routes.pop(sid, None)
        if method == "Target.targetDestroyed":
            owner = self._pages.get(params.get("targetId"))
            if owner is not None:
                owner._invalidate(destroyed=True)

    async def pages(self) -> list[JSON]:
        result = await self.cdp.send("Target.getTargets")
        return [dict(t) for t in result["targetInfos"] if t["type"] == "page"]

    async def attach(self, target_id: str, *, owned: bool = False) -> Page:
        page = self._pages.get(target_id)
        if page is not None and not page._destroyed:
            return page if page.attached else await page.reattach()
        async with self._lifecycle_lock:
            # Another attach may have completed while waiting for the lock.
            page = self._pages.get(target_id)
            if page is not None and not page._destroyed:
                if page.attached:
                    return page
                async with page._lock:
                    async with page._settings_lock:
                        return await page._reattach_locked(
                            restore_settings=True, max_message_bytes=None
                        )
            return await self._attach_new(target_id, owned=owned)

    async def _attach_new(self, target_id: str, *, owned: bool = False) -> Page:
        result = await self.cdp.send(
            "Target.attachToTarget", {"targetId": target_id, "flatten": True}
        )
        sid = result["sessionId"]
        page = Page(self, target_id, sid, owned=owned)
        self._pages[target_id] = page
        self._routes[sid] = page
        try:
            await page._initialize()
        except BaseException:
            self._pages.pop(target_id, None)
            page._invalidate()
            await page._stop_tasks()
            try:
                await self.cdp.send(
                    "Target.detachFromTarget", {"sessionId": sid}, timeout=2
                )
            except Exception:
                pass
            raise
        return page

    async def new_page(
        self, url: str = "about:blank", *, context_id: str | None = None
    ) -> Page:
        params: JSON = {"url": "about:blank"}
        if context_id is not None:
            params["browserContextId"] = context_id
        result = await self.cdp.send("Target.createTarget", params)
        target_id = result["targetId"]
        page = await self.attach(target_id, owned=True)
        if url != "about:blank":
            await page.goto(url)
        return page

    async def new_context(self) -> str:
        """Create isolated session storage. Dispose explicitly; disconnect leaves it alive."""
        context = (await self.cdp.send("Target.createBrowserContext"))[
            "browserContextId"
        ]
        self._contexts.add(context)
        return context

    async def dispose_context(self, context_id: str) -> None:
        if context_id not in self._contexts:
            raise UnsupportedOperation(
                "Will not dispose a context this connection did not create."
            )
        await self.cdp.send(
            "Target.disposeBrowserContext", {"browserContextId": context_id}
        )
        self._contexts.discard(context_id)

    def events(self, method: str, **options: Any) -> EventScope:
        return EventScope(self.cdp, method, **options)

    async def disconnect(self) -> None:
        """Disconnect only. Pages retain identity/settings for explicit reattach."""
        async with self._lifecycle_lock:
            await self._disconnect()

    async def _disconnect(self) -> None:
        for page in list(self._pages.values()):
            page._invalidate()
            await page._stop_tasks()
        await self._connection.close()
        self._routes.clear()

    async def _ensure_connection(self, max_message_bytes: int | None = None) -> bool:
        """Called only with the lifecycle lock held. Never launches another process."""
        old = self._connection
        if not old.closed:
            return False
        for page in list(self._pages.values()):
            page._invalidate()
            await page._stop_tasks()
        self._routes.clear()
        await old.close()
        replacement = await connect(
            self.endpoint,
            timeout=old.timeout,
            headers=self._headers,
            max_message_bytes=(
                old.max_message_bytes
                if max_message_bytes is None
                else max_message_bytes
            ),
        )
        # Transfer only transport ownership; the original Browser retains its
        # process, profiles, contexts and page handles. There is no await below.
        self._connection = replacement._connection
        self.cdp = CDPSession(self._connection)
        self.version = replacement.version
        self._connection.on_event = self._on_event
        return True

    @property
    def owns_process(self) -> bool:
        """Whether this handle was returned by spawn(), not connect()."""
        return self._owner is not None

    @property
    def pid(self) -> int | None:
        """Launched PID (retained for diagnostics after close), or None for connect()."""
        return self._owner.process.pid if self._owner and self._owner.process else None

    @property
    def profile(self) -> Path | None:
        """Owned profile path, or None; only temporary profiles are deleted on close."""
        return self._owner.profile if self._owner else None

    async def _close(self) -> None:
        async with self._lifecycle_lock:
            await self._close_locked()

    async def _close_locked(self) -> None:
        owner = self._owner
        try:
            if owner is not None and not self._connection.closed:
                try:
                    await self.cdp.send("Browser.close", timeout=2)
                except BrowserError:
                    pass  # Closing the browser can close the socket before its reply.
                await owner.wait(2)
        finally:
            try:
                await self._disconnect()
            finally:
                if owner is not None:
                    await owner.stop()

    async def close(self) -> None:
        """Disconnect; also stop Chrome and clean temporary data when spawned here.

        Attached browsers are never terminated. Idempotent, including concurrent
        close calls. Cancellation propagates after bounded cleanup completes.
        """
        from .launch import _finish_cleanup

        if self._close_task is None or (
            self._close_task.done()
            and (
                self._close_task.cancelled() or self._close_task.exception() is not None
            )
        ):
            self._close_task = asyncio.create_task(self._close(), name="browser-close")
        await _finish_cleanup(self._close_task)

    async def __aenter__(self) -> Browser:
        return self

    async def __aexit__(self, *exc: Any) -> None:
        await self.close()

    def __reduce_ex__(self, protocol: SupportsIndex, /) -> Any:
        raise TypeError(
            "Live browsers cannot be saved; save endpoint and page.descriptor()."
        )


async def connect(
    endpoint: str | None = None,
    *,
    timeout: float = 15,
    headers: dict[str, str] | None = None,
    max_message_bytes: int = 16 * 1024 * 1024,
) -> Browser:
    """Attach to a browser-level CDP endpoint; do not launch or own its process.

    Accepts an HTTP base URL (discovers /json/version) or a browser WebSocket URL.
    Headers are sent to discovery and the WebSocket handshake, but never saved in
    reconnect descriptors. Environment proxies are deliberately disabled.
    """
    positive(timeout, "timeout")
    endpoint = endpoint or os.environ.get(
        "ALBEDO_BROWSER_CDP_URL", "http://127.0.0.1:9222"
    )
    parsed = urlsplit(endpoint)
    if parsed.scheme not in {"http", "https", "ws", "wss"} or not parsed.hostname:
        raise ValueError("Expected an http(s) or ws(s) CDP endpoint")
    ws_url = endpoint
    if parsed.scheme in {"http", "https"}:
        path = parsed.path.rstrip("/")
        if not path.endswith("/json/version"):
            path += "/json/version"
        discovery = urlunsplit((parsed.scheme, parsed.netloc, path, parsed.query, ""))

        def _get_discovery() -> str:
            req = urllib.request.Request(discovery, headers=headers or {})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(req, timeout=timeout) as resp:
                data = json.loads(resp.read().decode("utf-8"))
                return str(data["webSocketDebuggerUrl"])

        try:
            ws_url = await asyncio.to_thread(_get_discovery)
        except Exception as exc:
            raise ConnectionLost(
                "CDP discovery failed. Start Chrome with a dedicated debugging profile, "
                "or supply a browser WebSocket URL.",
                cause=type(exc).__name__,
            ) from exc
        # Never forward caller-supplied credentials to an arbitrary discovery hostname.
        discovered = urlsplit(ws_url)
        if headers and (
            discovered.hostname != parsed.hostname
            or (parsed.scheme == "https" and discovered.scheme != "wss")
        ):
            raise ConnectionLost(
                "Discovery returned a different host; use its explicit WebSocket URL with appropriate credentials."
            )
    if "/devtools/page/" in ws_url:
        raise ValueError(
            "Use the browser endpoint from /json/version, not a page WebSocket URL"
        )
    connection = await Connection.open(
        ws_url, timeout=timeout, headers=headers, max_message_bytes=max_message_bytes
    )
    browser = Browser(connection, endpoint, headers=headers)
    try:
        browser.version = await browser.cdp.send("Browser.getVersion")
        await browser.cdp.send("Target.setDiscoverTargets", {"discover": True})
        return browser
    except BaseException:
        await browser.disconnect()
        raise
