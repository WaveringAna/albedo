"""WebSocket masking and the ssh bridge need a controlled peer that daemon E2E cannot expose."""

from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import os
from pathlib import Path
import struct
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
PRIV = ROOT / "priv" / "python"
sys.path.insert(0, str(PRIV))

from albedo_plugins.ws import SimpleWebSocketClient, mask  # noqa: E402

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


async def handshake(
    reader: asyncio.StreamReader, writer: asyncio.StreamWriter
) -> dict[str, str]:
    """Accept an upgrade; the request headers, lowercased."""
    headers: dict[str, str] = {}
    await reader.readline()
    while (line := await reader.readline()) not in (b"\r\n", b"\n", b""):
        name, _, value = line.decode("latin1").partition(":")
        headers[name.strip().lower()] = value.strip()
    accept = base64.b64encode(
        hashlib.sha1((headers["sec-websocket-key"] + GUID).encode("ascii")).digest()
    ).decode("ascii")
    writer.write(
        (
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"
        ).encode("ascii")
    )
    await writer.drain()
    return headers


async def read_frame(reader: asyncio.StreamReader) -> tuple[int, bytes]:
    """One client frame, which must be final and masked: (opcode, payload)."""
    b1, b2 = await reader.readexactly(2)
    assert b1 & 0x80 and b2 & 0x80, "client frames are final and masked"
    size = b2 & 0x7F
    if size == 126:
        (size,) = struct.unpack("!H", await reader.readexactly(2))
    elif size == 127:
        (size,) = struct.unpack("!Q", await reader.readexactly(8))
    key = await reader.readexactly(4)
    payload = await reader.readexactly(size)
    return b1 & 0x0F, bytes(byte ^ key[i % 4] for i, byte in enumerate(payload))


def server_frame(opcode: int, payload: bytes) -> bytes:
    if len(payload) <= 125:
        head = struct.pack("!BB", 0x80 | opcode, len(payload))
    else:
        head = struct.pack("!BBH", 0x80 | opcode, 126, len(payload))
    return head + payload


class WebSocketClientTest(unittest.IsolatedAsyncioTestCase):
    async def test_mask_is_its_own_inverse(self):
        key = b"\x01\x02\x03\x04"
        for size in (0, 1, 3, 4, 5, 1000):
            payload = os.urandom(size)
            masked = mask(payload, key)
            self.assertEqual(
                masked, bytes(b ^ key[i % 4] for i, b in enumerate(payload))
            )
            self.assertEqual(mask(masked, key), payload)

    async def test_text_and_binary_messages(self):
        received: list[tuple[int, bytes]] = []
        answered = asyncio.Event()
        big = os.urandom(70_000)

        async def handler(reader, writer):
            await handshake(reader, writer)
            received.append(await read_frame(reader))
            received.append(await read_frame(reader))
            received.append(await read_frame(reader))
            writer.write(server_frame(0x9, b"are you there"))  # ping
            writer.write(server_frame(0x1, b"echo: hello albedo"))
            writer.write(server_frame(0x2, b"\xff\x00\xfe"))
            await writer.drain()
            pong = await read_frame(reader)
            received.append(pong)
            answered.set()
            writer.close()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            client = await SimpleWebSocketClient.connect(f"ws://127.0.0.1:{port}/")
            await client.send("hello albedo")
            await client.send(b"\x00\x01binary")
            await client.send(big)
            self.assertEqual(await client.recv_message(), "echo: hello albedo")
            self.assertEqual(await client.recv_bytes(), b"\xff\x00\xfe")
            await client.close()
            # Closing the client does not wait for the server to read the
            # pong, and leaving `async with server` waits for handlers only
            # from Python 3.12.
            await asyncio.wait_for(answered.wait(), 10)
        self.assertEqual(
            received[:2], [(0x1, b"hello albedo"), (0x2, b"\x00\x01binary")]
        )
        self.assertEqual(received[2], (0x2, big))
        self.assertEqual(received[3], (0xA, b"are you there"))


class BridgeTest(unittest.IsolatedAsyncioTestCase):
    async def test_stdio_is_copied_both_ways_with_headers_from_the_environment(self):
        seen: dict[str, str] = {}

        async def handler(reader, writer):
            seen.update(await handshake(reader, writer))
            while True:
                opcode, payload = await read_frame(reader)
                if opcode == 0x8:
                    break
                writer.write(server_frame(0x2, payload.upper()))
                await writer.drain()
            writer.close()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            process = await asyncio.create_subprocess_exec(
                sys.executable,
                "-m",
                "albedo_plugins.ws",
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                env={
                    **os.environ,
                    "PYTHONPATH": str(PRIV),
                    "ALBEDO_WS_URL": f"ws://127.0.0.1:{port}/colab/ssh?token=secret",
                    "ALBEDO_WS_HEADERS": json.dumps({"X-Test": "yes"}),
                },
            )
            assert process.stdin and process.stdout
            process.stdin.write(b"ssh bytes")
            await process.stdin.drain()
            echoed = await asyncio.wait_for(process.stdout.readexactly(9), 10)
            process.stdin.close()
            await asyncio.wait_for(process.wait(), 10)

        self.assertEqual(echoed, b"SSH BYTES")
        self.assertEqual(seen["x-test"], "yes")
        self.assertEqual(process.returncode, 0)

    async def test_missing_url_fails_with_a_message(self):
        environment = {k: v for k, v in os.environ.items() if k != "ALBEDO_WS_URL"}
        process = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "albedo_plugins.ws",
            stdin=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            env={**environment, "PYTHONPATH": str(PRIV)},
        )
        _, stderr = await process.communicate()
        self.assertEqual(process.returncode, 1)
        self.assertIn("ALBEDO_WS_URL", stderr.decode())


if __name__ == "__main__":
    unittest.main()
