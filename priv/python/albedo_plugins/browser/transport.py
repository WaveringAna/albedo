"""One reader owns the socket. It never awaits a consumer or user callback."""

from __future__ import annotations

from typing import SupportsIndex

import asyncio
import copy
import json
import math
from collections.abc import Callable
from typing import Any

from albedo_plugins.ws import ConnectionClosed, SimpleWebSocketClient

from .errors import (
    BrowserError,
    CommandTimeout,
    ConnectionLost,
    EventOverflow,
    ProtocolError,
    WaitTimeout,
)

JSON = dict[str, Any]


def positive(value: float, name: str) -> float:
    if isinstance(value, bool) or not math.isfinite(value) or value <= 0:
        raise ValueError(f"{name} must be finite and positive")
    return value


class Subscription:
    def __init__(
        self,
        connection: Connection,
        method: str,
        session_id: str | None,
        capacity: int,
        max_bytes: int,
    ) -> None:
        if capacity < 1 or max_bytes < 1:
            raise ValueError("event capacity and max_bytes must be positive")
        self.connection = connection
        self.method = method
        self.session_id = session_id
        self.capacity = capacity
        self.max_bytes = max_bytes
        self._queue: asyncio.Queue[tuple[JSON, int] | None] = asyncio.Queue(capacity)
        self._bytes = 0
        self._error: BrowserError | None = None
        self._closed = False

    def _push(self, params: JSON, size: int) -> None:
        if self._closed:
            return
        if self._queue.full() or self._bytes + size > self.max_bytes:
            self._fail(
                EventOverflow(
                    "Event buffer overflowed; this subscription is no longer complete.",
                    method=self.method,
                    capacity=self.capacity,
                    max_bytes=self.max_bytes,
                    recovery="Create a new subscription; do not assume no event occurred.",
                )
            )
            return
        self._queue.put_nowait((copy.deepcopy(params), size))
        self._bytes += size

    def _fail(self, error: BrowserError) -> None:
        self._error = error
        self.close()

    def close(self) -> None:
        self._closed = True
        self.connection._subscriptions.discard(self)
        while not self._queue.empty():
            self._queue.get_nowait()
        self._bytes = 0
        self._queue.put_nowait(None)

    async def next(
        self,
        *,
        where: Callable[[JSON], bool] | None = None,
        timeout: float = 10,
    ) -> JSON:
        """Return one payload. A predicate consumes unmatched events on this stream."""
        positive(timeout, "timeout")
        try:
            async with asyncio.timeout(timeout):
                while True:
                    if self._error is not None:
                        raise self._error
                    if self._closed:
                        raise ConnectionLost("Event subscription is closed.")
                    item = await self._queue.get()
                    if item is None:
                        if self._error is not None:
                            raise self._error
                        raise ConnectionLost("Event subscription is closed.")
                    params, size = item
                    self._bytes -= size
                    if where is None or where(params):
                        return params
        except TimeoutError as exc:
            raise WaitTimeout(
                "No matching event before the deadline.", method=self.method
            ) from exc

    def drain(self) -> list[JSON]:
        """Take the currently buffered payloads without waiting."""
        if self._error is not None:
            raise self._error
        result = []
        while not self._queue.empty():
            item = self._queue.get_nowait()
            if item is not None:
                params, size = item
                self._bytes -= size
                result.append(params)
        return result

    def __reduce_ex__(self, protocol: SupportsIndex, /) -> Any:
        raise TypeError(
            "Live event subscriptions cannot be saved; drain them to ordinary data."
        )


class Connection:
    def __init__(
        self,
        socket: SimpleWebSocketClient,
        *,
        timeout: float,
        max_message_bytes: int = 16 * 1024 * 1024,
    ) -> None:
        self.socket = socket
        self.max_message_bytes = max_message_bytes
        self._detached_sessions: set[str] = set()
        self.timeout = positive(timeout, "timeout")
        self._next_id = 0
        self._pending: dict[int, asyncio.Future[JSON]] = {}
        self._subscriptions: set[Subscription] = set()
        self._pending_sessions: dict[int, str | None] = {}
        self._closed: ConnectionLost | None = None
        self.on_event: Callable[[str, JSON, str | None], None] | None = None
        self._reader = asyncio.create_task(self._read(), name="browser-cdp-reader")

    @classmethod
    async def open(
        cls,
        url: str,
        *,
        timeout: float = 15,
        headers: dict[str, str] | None = None,
        max_message_bytes: int = 16 * 1024 * 1024,
    ) -> Connection:
        positive(timeout, "timeout")
        if max_message_bytes < 1024:
            raise ValueError("max_message_bytes must be at least 1024")
        try:
            socket = await SimpleWebSocketClient.connect(
                url,
                headers=headers,
                timeout=timeout,
                max_message_bytes=max_message_bytes,
            )
        except Exception as exc:
            raise ConnectionLost(
                "Could not open the CDP WebSocket.", cause=type(exc).__name__
            ) from exc
        return cls(socket, timeout=timeout, max_message_bytes=max_message_bytes)

    @property
    def closed(self) -> bool:
        return self._closed is not None

    def subscribe(
        self,
        method: str,
        session_id: str | None,
        *,
        capacity: int = 256,
        max_bytes: int = 2 * 1024 * 1024,
    ) -> Subscription:
        if self._closed is not None:
            raise self._closed
        if session_id in self._detached_sessions:
            raise ConnectionLost(
                "Target session detached; use await page.reattach().",
                session_id=session_id,
            )
        if len(self._subscriptions) >= 64:
            raise ValueError("At most 64 live event subscriptions per connection")
        sub = Subscription(self, method, session_id, capacity, max_bytes)
        self._subscriptions.add(sub)
        return sub

    async def send(
        self,
        method: str,
        params: JSON | None = None,
        *,
        session_id: str | None = None,
        timeout: float | None = None,
    ) -> JSON:
        duration = positive(self.timeout if timeout is None else timeout, "timeout")
        if self._closed is not None:
            raise self._closed
        if session_id in self._detached_sessions:
            raise ConnectionLost(
                "Target session detached; use await page.reattach().",
                session_id=session_id,
            )
        if not isinstance(method, str) or "." not in method:
            raise ValueError("method must be a CDP Domain.command name")
        if len(self._pending) >= 256:
            raise ValueError("At most 256 in-flight CDP commands per connection")
        self._next_id += 1
        request_id = self._next_id
        request = {"id": request_id, "method": method, "params": params or {}}
        if session_id is not None:
            request["sessionId"] = session_id
        encoded = json.dumps(request, allow_nan=False)
        future: asyncio.Future[JSON] = asyncio.get_running_loop().create_future()
        self._pending[request_id] = future
        self._pending_sessions[request_id] = session_id
        sent = False
        try:
            async with asyncio.timeout(duration):
                sent = True
                await self.socket.send(encoded)
                reply = await future
            if "error" in reply:
                error = reply["error"]
                raise ProtocolError(
                    error.get("message", "CDP command failed"),
                    method=method,
                    code=error.get("code"),
                    data=error.get("data"),
                )
            return reply.get("result", {})
        except TimeoutError as exc:
            raise CommandTimeout(
                "CDP command exceeded its deadline; it was not replayed.",
                method=method,
                may_have_executed=sent,
                timeout=duration,
            ) from exc
        except ConnectionClosed as exc:
            raise ConnectionLost(
                "CDP connection closed.", method=method, may_have_executed=sent
            ) from exc
        finally:
            self._pending.pop(request_id, None)
            self._pending_sessions.pop(request_id, None)
            if not future.done():
                future.cancel()
            elif not future.cancelled():
                future.exception()

    def detach_session(self, session_id: str | None) -> None:
        if session_id is None:
            return
        self._detached_sessions.add(session_id)
        error = ConnectionLost(
            "Target session detached; use await page.reattach().", session_id=session_id
        )
        for request_id, sid in tuple(self._pending_sessions.items()):
            if sid == session_id:
                future = self._pending.get(request_id)
                if future is not None and not future.done():
                    future.set_exception(error)
        for sub in tuple(self._subscriptions):
            if sub.session_id == session_id:
                sub._fail(error)

    def _fail(self, error: ConnectionLost) -> None:
        if self._closed is not None:
            return
        self._closed = error
        for future in self._pending.values():
            if not future.done():
                future.set_exception(error)
        for sub in tuple(self._subscriptions):
            sub._fail(error)

    async def _read(self) -> None:
        try:
            async for raw in self.socket:
                message = json.loads(raw)
                if not isinstance(message, dict):
                    raise ValueError("CDP message is not an object")
                if "id" in message:
                    future = self._pending.get(message["id"])
                    if future is not None and not future.done():
                        future.set_result(message)
                    continue
                method = message.get("method", "")
                params = message.get("params", {})
                session_id = message.get("sessionId")
                if self.on_event is not None:
                    self.on_event(method, params, session_id)
                for sub in tuple(self._subscriptions):
                    if sub.method == method and sub.session_id == session_id:
                        sub._push(params, len(raw))
        except asyncio.CancelledError:
            raise
        except Exception as exc:
            details: JSON = {
                "cause": type(exc).__name__,
                "max_message_bytes": self.max_message_bytes,
            }
            if isinstance(exc, ConnectionClosed):
                close = (
                    exc.sent
                    if exc.sent and exc.sent.code == 1009
                    else (exc.rcvd or exc.sent)
                )
                if close is not None:
                    details.update(close_code=close.code, close_reason=close.reason)
            if details.get("close_code") == 1009:
                message = (
                    "CDP message exceeded max_message_bytes; event history has a gap. "
                    "Reattach explicitly with a larger finite max_message_bytes budget."
                )
            else:
                message = "CDP reader stopped; event history has a gap. Use await page.reattach()."
            self._fail(ConnectionLost(message, **details))
        finally:
            self._fail(ConnectionLost("CDP disconnected; event history has a gap."))
            await self.socket.close()

    async def close(self) -> None:
        self._fail(ConnectionLost("CDP connection explicitly disconnected."))
        try:
            await self.socket.close()
        finally:
            self._reader.cancel()
            await asyncio.gather(self._reader, return_exceptions=True)

    def __reduce_ex__(self, protocol: SupportsIndex, /) -> Any:
        raise TypeError(
            "A live CDP connection cannot be saved; save a reconnect descriptor."
        )


class CDPSession:
    """A session-bound escape hatch. Raw commands bypass high-level safety checks."""

    def __init__(self, connection: Connection, session_id: str | None = None) -> None:
        self.connection = connection
        self.session_id = session_id

    async def send(
        self,
        method: str,
        params: JSON | None = None,
        *,
        timeout: float | None = None,
    ) -> JSON:
        return await self.connection.send(
            method, params, session_id=self.session_id, timeout=timeout
        )
