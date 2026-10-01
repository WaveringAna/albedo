"""MCP stdio discovery, credentials, namespaced calls, and teardown through the daemon."""

from typing import Any
import json
import sys
import time
import unittest
import urllib.error
from pathlib import Path

from harness import Albedo, Provider, exclusive, Reply, text

SERVER = Path(__file__).with_name("fake_mcp_server.py")


class McpTests(unittest.TestCase):
    def setUp(self):
        self.message = "ping from albedo"

        def script(request):
            tools = sorted(tool["name"] for tool in request.get("tools", []))
            answered = any(
                item.get("type") == "function_call_output" for item in request["input"]
            )
            mcp_tool = next((name for name in tools if name.startswith("mcp_")), None)
            if mcp_tool and not answered:
                return Reply(
                    "python",
                    tool_name=mcp_tool,
                    tool_arguments={"message": self.message},
                )
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)

        def prepare(app):
            app.env.update(
                ALBEDO_MCP_SECRET="configured-secret",
                ALBEDO_MCP_CLOSED=str(app.root / "closed"),
                ALBEDO_MCP_AMBIENT="must-not-reach-the-server",
            )
            self.configure(app, [str(SERVER)])
            app.store_secrets(
                "mcp", {"fake": {"env": {"FAKE_SECRET": "stored-secret"}}}
            )

        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()
        self.route = f"/sessions/{self.session}/extensions"

    def configure(self, app, args, startup=20000):
        path = app.home / "extensions.json"
        settings: dict[str, Any] = (
            json.loads(path.read_text())
            if path.exists()
            else {"models": {"refreshHours": 0}}
        )
        settings["mcp"] = {
            "servers": {
                "fake": {
                    "type": "stdio",
                    "command": sys.executable,
                    "args": args,
                    "env": {
                        "FAKE_SECRET": {"env": "ALBEDO_MCP_SECRET"},
                        "FAKE_MCP_CLOSED": {"env": "ALBEDO_MCP_CLOSED"},
                    },
                    "startupTimeoutMs": startup,
                }
            }
        }
        path.write_text(json.dumps(settings))

    def extension(self, body=None):
        with self.app.api(self.route, body) as response:
            return next(item for item in json.load(response) if item["name"] == "mcp")

    def turn(self, prompt):
        before = len(self.provider.requests)
        self.app.prompt(self.session, prompt).close()
        self.app.idle(self.session, timeout=60)
        return [entry["request"] for entry in self.provider.requests[before:]]

    def test_discovery_namespaced_call_and_scrubbed_credentials(self):
        enabled = self.extension({"name": "mcp", "enabled": True})
        self.assertTrue(enabled["enabled"])
        self.assertEqual(enabled["plugins"], ["managed"])
        requests = self.turn("use the mcp server")
        self.assertEqual(len(requests), 2)
        context = requests[0]["instructions"]
        self.assertNotIn("<extension-context", json.dumps(requests[0]["input"]))
        self.assertIn('name="mcp"', context)
        self.assertIn("echo", context)
        advertised = [
            tool["name"]
            for tool in requests[0]["tools"]
            if tool["name"].startswith("mcp_")
        ]
        self.assertEqual(len(advertised), 1)
        self.assertTrue(advertised[0].startswith("mcp_fake_echo_"))
        output = next(
            item["output"]
            for item in requests[1]["input"]
            if item.get("type") == "function_call_output"
        )
        self.assertEqual(
            json.loads(json.loads(output)["content"][0]["text"]),
            {"echoed": "ping from albedo", "secret": "stored-secret", "ambient": None},
        )
        self.assertEqual(self.extension()["tools"], advertised)

    def test_a_failed_tool_call_is_refused_without_ending_the_turn(self):
        self.extension({"name": "mcp", "enabled": True})
        self.message = "fail"
        requests = self.turn("the server will refuse")
        self.assertEqual(len(requests), 2)
        output = next(
            item["output"]
            for item in requests[1]["input"]
            if item.get("type") == "function_call_output"
        )
        self.assertIn("MCP request failed", json.loads(output)["error"])
        self.assertIn("done", json.dumps(self.app.history(self.session)))

    @exclusive
    def test_disable_closes_server_and_removes_tools(self):
        self.extension({"name": "mcp", "enabled": True})
        disabled = self.extension({"name": "mcp", "enabled": False})
        self.assertFalse(disabled["enabled"])
        closed = self.app.root / "closed"
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not closed.exists():
            time.sleep(0.05)
        self.assertTrue(closed.exists(), "disabling must close the server")
        requests = self.turn("the server is gone")
        self.assertFalse(
            any(tool["name"].startswith("mcp_") for tool in requests[0]["tools"])
        )

    @exclusive
    def test_insecure_credentials_and_unavailable_server_fail_closed(self):
        credentials = self.app.home / "creds.json"
        credentials.chmod(0o644)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.extension({"name": "mcp", "enabled": True})
        self.assertEqual(rejected.exception.code, 409)
        credentials.chmod(0o600)
        self.configure(self.app, [str(self.app.root / "missing.py")], startup=3000)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.extension({"name": "mcp", "enabled": True})
        self.assertEqual(rejected.exception.code, 409)
        self.assertFalse(self.extension()["enabled"])
