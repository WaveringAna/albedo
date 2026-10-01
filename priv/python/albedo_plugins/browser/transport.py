"""One reader owns the socket. It never awaits a consumer or user callback."""

from __future__ import annotations

import asyncio
import base64
import copy
from dataclasses import dataclass
import hashlib
import json
import math
import os
import struct
import urllib.parse
from collections.abc import Callable
from typing import Any

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


@dataclass
class CloseFrame:
    code: int
    reason: str


class ConnectionClosed(Exception):
    def __init__(self, code: int = 1006, reason: str = "") -> None:
        super().__init__(f"WebSocket closed: {code} {reason}")
        self.code = code
        self.reason = reason
        self.rcvd = CloseFrame(code, reason)
        self.sent: CloseFrame | None = None


class SimpleWebSocketClient:
    def __init__(
        self,
        reader: asyncio.StreamReader,
        writer: asyncio.StreamWriter,
        max_message_bytes: int = 16 * 1024 * 1024,
    ) -> None:
        self.reader = reader
        self.writer = writer
        self.max_message_bytes = max_message_bytes
        self._closed = False
        self._close_sent = False
        self.close_code: int | None = None
        self.close_reason: str = ""

    @classmethod
    async def connect(
        cls,
        url: str,
        *,
        headers: dict[str, str] | None = None,
        timeout: float = 15,
        max_message_bytes: int = 16 * 1024 * 1024,
    ) -> SimpleWebSocketClient:
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme not in ("ws", "wss"):
            raise ValueError(f"Expected ws:// or wss:// URL, got: {url!r}")
        hostname = parsed.hostname or "127.0.0.1"
        port = parsed.port or (443 if parsed.scheme == "wss" else 80)
        ssl_ctx = True if parsed.scheme == "wss" else None

        async with asyncio.timeout(timeout):
            reader, writer = await asyncio.open_connection(
                hostname, port, ssl=ssl_ctx, limit=max_message_bytes
            )
            key = base64.b64encode(os.urandom(16)).decode("ascii")
            path = parsed.path or "/"
            if parsed.query:
                path = f"{path}?{parsed.query}"

            host_header = f"{hostname}:{port}" if parsed.port else hostname
            lines = [
                f"GET {path} HTTP/1.1",
                f"Host: {host_header}",
                "Upgrade: websocket",
                "Connection: Upgrade",
                f"Sec-WebSocket-Key: {key}",
                "Sec-WebSocket-Version: 13",
            ]
            if headers:
                for k, v in headers.items():
                    lines.append(f"{k}: {v}")
            raw_req = "\r\n".join(lines) + "\r\n\r\n"
            writer.write(raw_req.encode("ascii"))
            await writer.drain()

            status_line = await reader.readline()
            if not status_line:
                writer.close()
                raise ConnectionClosed(1006, "EOF during WebSocket handshake")
            parts = status_line.decode("latin1").split(" ", 2)
            if len(parts) < 2 or parts[1] != "101":
                body = await reader.read(4096)
                writer.close()
                raise ConnectionClosed(
                    1002,
                    f"Handshake failed: {status_line.decode('latin1').strip()} {body.decode('latin1', errors='replace')}",
                )

            resp_headers: dict[str, str] = {}
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
                hparts = line.decode("latin1").split(":", 1)
                if len(hparts) == 2:
                    resp_headers[hparts[0].strip().lower()] = hparts[1].strip()

            expected_accept = base64.b64encode(
                hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
                ).digest()
            ).decode("ascii")
            accept = resp_headers.get("sec-websocket-accept")
            if accept != expected_accept:
                writer.close()
                raise ConnectionClosed(
                    1002,
                    f"Sec-WebSocket-Accept mismatch: expected {expected_accept}, got {accept}",
                )

            return cls(reader, writer, max_message_bytes=max_message_bytes)

    async def send(self, data: str) -> None:
        if self._closed:
            raise ConnectionClosed(self.close_code or 1000, self.close_reason)
        payload = data.encode("utf-8")
        mask_key = os.urandom(4)
        length = len(payload)

        header = bytearray([0x80 | 0x1])  # FIN=1, Opcode=TEXT
        if length <= 125:
            header.append(0x80 | length)
        elif length <= 65535:
            header.append(0x80 | 126)
            header.extend(struct.pack("!H", length))
        else:
            header.append(0x80 | 127)
            header.extend(struct.pack("!Q", length))
        header.extend(mask_key)

        masked = bytearray(payload)
        for i in range(length):
            masked[i] ^= mask_key[i % 4]

        self.writer.write(header + masked)
        await self.writer.drain()

    async def recv_message(self) -> str:
        fragments: list[bytes] = []
        msg_opcode: int | None = None
        total_len = 0

        while True:
            if self._closed:
                raise ConnectionClosed(self.close_code or 1000, self.close_reason)

            try:
                head = await self.reader.readexactly(2)
            except (
                asyncio.IncompleteReadError,
                ConnectionResetError,
                BrokenPipeError,
            ) as exc:
                self._closed = True
                raise ConnectionClosed(1006, "Connection closed abruptly") from exc

            b1, b2 = head[0], head[1]
            fin = bool(b1 & 0x80)
            opcode = b1 & 0x0F
            is_masked = bool(b2 & 0x80)
            payload_len = b2 & 0x7F

            if payload_len == 126:
                ext = await self.reader.readexactly(2)
                payload_len = struct.unpack("!H", ext)[0]
            elif payload_len == 127:
                ext = await self.reader.readexactly(8)
                payload_len = struct.unpack("!Q", ext)[0]

            total_len += payload_len
            if total_len > self.max_message_bytes:
                await self.close(1009, "Message exceeds size limit")
                exc = ConnectionClosed(
                    1009, f"Message exceeded max_message_bytes {self.max_message_bytes}"
                )
                exc.sent = CloseFrame(1009, "Message exceeds size limit")
                raise exc

            if is_masked:
                mask_key = await self.reader.readexactly(4)

            payload = await self.reader.readexactly(payload_len)
            if is_masked:
                unmasked = bytearray(payload)
                for i in range(len(unmasked)):
                    unmasked[i] ^= mask_key[i % 4]
                payload = bytes(unmasked)

            if opcode == 0x8:  # CLOSE
                code = 1000
                reason = ""
                if len(payload) >= 2:
                    code = struct.unpack("!H", payload[:2])[0]
                    reason = payload[2:].decode("utf-8", errors="replace")
                self.close_code = code
                self.close_reason = reason
                self._closed = True
                if not self._close_sent:
                    try:
                        self._close_sent = True
                        close_resp = bytearray([0x80 | 0x8, 0x80])
                        mask = os.urandom(4)
                        close_resp.extend(mask)
                        self.writer.write(close_resp)
                        await self.writer.drain()
                        self.writer.close()
                    except Exception:
                        pass
                raise ConnectionClosed(code, reason)
            elif opcode == 0x9:  # PING
                pong = bytearray([0x80 | 0xA, 0x80 | (len(payload) & 0x7F)])
                mask = os.urandom(4)
                pong.extend(mask)
                masked_pong = bytearray(payload)
                for i in range(len(masked_pong)):
                    masked_pong[i] ^= mask[i % 4]
                self.writer.write(pong + masked_pong)
                await self.writer.drain()
                continue
            elif opcode == 0xA:  # PONG
                continue
            elif opcode in (0x1, 0x2):  # TEXT or BINARY
                msg_opcode = opcode
                fragments.append(payload)
                if fin:
                    break
            elif opcode == 0x0:  # CONTINUATION
                fragments.append(payload)
                if fin:
                    break
            else:
                raise ConnectionClosed(1002, f"Unknown WebSocket opcode: {opcode}")

        raw_bytes = b"".join(fragments)
        return raw_bytes.decode("utf-8", errors="replace")

    def __aiter__(self) -> SimpleWebSocketClient:
        return self

    async def __anext__(self) -> str:
        try:
            return await self.recv_message()
        except ConnectionClosed:
            raise StopAsyncIteration

    async def close(self, code: int = 1000, reason: str = "") -> None:
        if self._closed and self._close_sent:
            return
        self._closed = True
        if not self._close_sent:
            self._close_sent = True
            try:
                reason_bytes = reason.encode("utf-8")[:123]
                payload = struct.pack("!H", code) + reason_bytes
                mask = os.urandom(4)
                length = len(payload)
                header = bytearray([0x80 | 0x8, 0x80 | length])
                header.extend(mask)
                masked = bytearray(payload)
                for i in range(length):
                    masked[i] ^= mask[i % 4]
                self.writer.write(header + masked)
                await self.writer.drain()
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass


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

    def __reduce_ex__(self, protocol: int) -> Any:
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

    def __reduce_ex__(self, protocol: int) -> Any:
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
