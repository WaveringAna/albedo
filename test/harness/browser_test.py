"""Tests for the browser extension: WebSocket transport, CDP session, and page interactions."""

from __future__ import annotations

import asyncio
import base64
import hashlib
from pathlib import Path
import shutil
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "priv" / "python"))

from albedo_plugins.browser.transport import SimpleWebSocketClient
from albedo_plugins.browser import spawn, render, one


class WebSocketClientUnitTest(unittest.IsolatedAsyncioTestCase):
    """Test the pure-Python RFC 6455 client against an asyncio mock server."""

    async def test_handshake_and_echo(self):
        received_frames: list[str] = []

        async def handler(reader: asyncio.StreamReader, writer: asyncio.StreamWriter):
            key = ""
            while True:
                line = await reader.readline()
                if line in (b"\r\n", b"\n", b""):
                    break
                if line.lower().startswith(b"sec-websocket-key:"):
                    key = line.split(b":", 1)[1].strip().decode("ascii")

            accept = base64.b64encode(
                hashlib.sha1(
                    (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode("ascii")
                ).digest()
            ).decode("ascii")
            resp = (
                f"HTTP/1.1 101 Switching Protocols\r\n"
                f"Upgrade: websocket\r\n"
                f"Connection: Upgrade\r\n"
                f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
            ).encode("ascii")
            writer.write(resp)
            await writer.drain()

            # Read frame from client (client masks frames)
            head = await reader.readexactly(2)
            b1, b2 = head[0], head[1]
            length = b2 & 0x7F
            mask = await reader.readexactly(4)
            payload = await reader.readexactly(length)
            unmasked = bytearray(payload)
            for i in range(len(unmasked)):
                unmasked[i] ^= mask[i % 4]
            received_frames.append(unmasked.decode("utf-8"))

            # Send back echo frame unmasked
            msg = b"echo: " + bytes(unmasked)
            frame = bytearray([0x81, len(msg)]) + msg
            writer.write(frame)
            await writer.drain()

            writer.close()
            await writer.wait_closed()

        server = await asyncio.start_server(handler, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            client = await SimpleWebSocketClient.connect(f"ws://127.0.0.1:{port}/")
            await client.send("hello albedo")
            reply = await client.recv_message()
            self.assertEqual(reply, "echo: hello albedo")
            self.assertEqual(received_frames, ["hello albedo"])
            await client.close()


class BrowserIntegrationTest(unittest.IsolatedAsyncioTestCase):
    """End-to-end integration tests using local Chromium if present."""

    async def asyncSetUp(self):
        self.has_chrome = (
            shutil.which("chromium") is not None
            or shutil.which("google-chrome") is not None
            or Path("/Applications/Chromium.app/Contents/MacOS/Chromium").exists()
            or Path(
                "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            ).exists()
        )

    async def test_spawn_navigate_observe_interact_close(self):
        if not self.has_chrome:
            self.skipTest("No Chrome or Chromium installed on this system")

        b = await spawn(headless=True)
        try:
            page = await b.new_page()
            html = (
                "data:text/html,"
                "<!doctype html>"
                "<html><head><title>Albedo Test</title></head>"
                "<body>"
                "<h1>Header</h1>"
                "<label for='name'>Name</label><input id='name' value='initial'>"
                "<button id='save' onclick='window.clicked=true'>Save</button>"
                "</body></html>"
            )
            await page.goto(html)

            # Observe
            obs = await page.observe()
            self.assertEqual(obs["title"], "Albedo Test")
            text = render(obs)
            self.assertIn("Header", text)
            self.assertIn("Save", text)

            # Find and One
            btn = one(obs, role="button", name="Save")
            self.assertIsNotNone(btn)
            field = one(obs, role="textbox", name="Name")
            self.assertIsNotNone(field)

            # Fill and Click
            await page.fill(field, "new value")
            self.assertEqual(
                await page.evaluate("document.querySelector('#name').value"),
                "new value",
            )

            await page.click(btn)
            self.assertTrue(await page.evaluate("window.clicked"))

            # Close page
            await page.close()
        finally:
            await b.close()


if __name__ == "__main__":
    unittest.main()
