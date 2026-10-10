"""A small asyncio WebSocket client, and a stdio bridge for ssh's ProxyCommand.

    python -m albedo_plugins.ws    # ALBEDO_WS_URL, and ALBEDO_WS_HEADERS as a JSON object

The bridge copies stdin to binary messages and messages to stdout until either
side ends. The url and headers travel in the environment because they carry
tokens, which a command line would show to every process on the host.
"""

from __future__ import annotations

import asyncio
import base64
from dataclasses import dataclass
import hashlib
import json
import os
import struct
import sys
import urllib.parse

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
TEXT, BINARY, CLOSE, PING, PONG, CONTINUATION = 0x1, 0x2, 0x8, 0x9, 0xA, 0x0


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


def mask(payload: bytes, key: bytes) -> bytes:
    """`payload` XORed with the repeating 4-byte `key`; applying it twice undoes it."""
    size = len(payload)
    stream = (key * (size // 4 + 1))[:size]
    return (int.from_bytes(payload, "big") ^ int.from_bytes(stream, "big")).to_bytes(
        size, "big"
    )


def frame(opcode: int, payload: bytes) -> bytes:
    """One final, masked client frame."""
    key = os.urandom(4)
    size = len(payload)
    if size <= 125:
        head = struct.pack("!BB", 0x80 | opcode, 0x80 | size)
    elif size <= 0xFFFF:
        head = struct.pack("!BBH", 0x80 | opcode, 0x80 | 126, size)
    else:
        head = struct.pack("!BBQ", 0x80 | opcode, 0x80 | 127, size)
    return head + key + mask(payload, key)


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
                hashlib.sha1((key + GUID).encode("ascii")).digest()
            ).decode("ascii")
            accept = resp_headers.get("sec-websocket-accept")
            if accept != expected_accept:
                writer.close()
                raise ConnectionClosed(
                    1002,
                    f"Sec-WebSocket-Accept mismatch: expected {expected_accept}, got {accept}",
                )

            return cls(reader, writer, max_message_bytes=max_message_bytes)

    async def send(self, data: str | bytes) -> None:
        """Send one text message for a str, one binary message for bytes."""
        if self._closed:
            raise ConnectionClosed(self.close_code or 1000, self.close_reason)
        if isinstance(data, str):
            self.writer.write(frame(TEXT, data.encode("utf-8")))
        else:
            self.writer.write(frame(BINARY, data))
        await self.writer.drain()

    async def recv_bytes(self) -> bytes:
        """The next message's bytes; control frames are answered on the way."""
        fragments: list[bytes] = []
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

            key = await self.reader.readexactly(4) if is_masked else b""
            payload = await self.reader.readexactly(payload_len)
            if is_masked:
                payload = mask(payload, key)

            if opcode == CLOSE:
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
                        self.writer.write(frame(CLOSE, b""))
                        await self.writer.drain()
                        self.writer.close()
                    except Exception:
                        pass
                raise ConnectionClosed(code, reason)
            elif opcode == PING:
                self.writer.write(frame(PONG, payload))
                await self.writer.drain()
            elif opcode == PONG:
                continue
            elif opcode in (TEXT, BINARY, CONTINUATION):
                fragments.append(payload)
                if fin:
                    return b"".join(fragments)
            else:
                raise ConnectionClosed(1002, f"Unknown WebSocket opcode: {opcode}")

    async def recv_message(self) -> str:
        return (await self.recv_bytes()).decode("utf-8", errors="replace")

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
                payload = struct.pack("!H", code) + reason.encode("utf-8")[:123]
                self.writer.write(frame(CLOSE, payload))
                await self.writer.drain()
                self.writer.close()
                await self.writer.wait_closed()
            except Exception:
                pass


async def bridge(url: str, headers: dict[str, str]) -> None:
    """Copy stdin to the socket and the socket to stdout until either ends."""
    socket = await SimpleWebSocketClient.connect(url, headers=headers)
    loop = asyncio.get_running_loop()
    stdin = asyncio.StreamReader()
    await loop.connect_read_pipe(
        lambda: asyncio.StreamReaderProtocol(stdin), sys.stdin.buffer
    )

    async def upstream() -> None:
        while chunk := await stdin.read(65536):
            await socket.send(chunk)

    async def downstream() -> None:
        try:
            while True:
                sys.stdout.buffer.write(await socket.recv_bytes())
                sys.stdout.buffer.flush()
        except ConnectionClosed:
            pass

    tasks = [asyncio.create_task(upstream()), asyncio.create_task(downstream())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await socket.close()


def main() -> int:
    try:
        url = os.environ["ALBEDO_WS_URL"]
        headers = json.loads(os.environ.get("ALBEDO_WS_HEADERS", "{}"))
        asyncio.run(bridge(url, headers))
    except (KeyError, ValueError, OSError, ConnectionClosed) as error:
        sys.stderr.write(f"ws bridge: {error!r}\n")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
