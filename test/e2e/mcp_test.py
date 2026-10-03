"""MCP stdio discovery, credentials, namespaced calls, and teardown through the daemon."""

from typing import Any
from concurrent.futures import ThreadPoolExecutor
import errno
import json
import os
import shutil
import sys
import time
import unittest
from pathlib import Path

from harness import Albedo, Provider, exclusive, operation_id, Reply, text

SERVER = Path(__file__).with_name("fake_mcp_server.py")


# exclusive: fixture configures global MCP servers, credentials, and daemon environment
@exclusive
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
                ALBEDO_MCP_CONTROL=str(app.root / "control"),
            )
            (app.root / "control").mkdir()
            self.configure(app, [str(SERVER)])
            app.store_secrets(
                "mcp", {"fake": {"env": {"FAKE_SECRET": "stored-secret"}}}
            )

        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def configure(self, app, args, startup=20000, retry=None):
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
                        "FAKE_MCP_CONTROL": {"env": "ALBEDO_MCP_CONTROL"},
                    },
                    "startupTimeoutMs": startup,
                }
            }
        }
        if retry is not None:
            settings["mcp"]["retryMs"] = retry
        path.write_text(json.dumps(settings))

    def tools(self, requests):
        return [
            tool["name"]
            for tool in requests[0]["tools"]
            if tool["name"].startswith("mcp_")
        ]

    def mcp(self):
        with self.app.api(f"/sessions/{self.session}/catalog") as response:
            catalog = json.load(response)
        return next(
            row
            for row in catalog["discovery"]["candidates"]
            if row["kind"] == "extension" and row["preference_key"] == "mcp"
        )

    def select_mcp(self, session, enabled):
        route = f"/sessions/{session}?view=configuration"
        with self.app.api(route) as response:
            json.load(response)
            etag = response.headers["ETag"]
        self.app.api(
            route,
            {"selection": {"extensions": {"mcp": enabled}}},
            method="PATCH",
            headers={"If-Match": etag},
        ).close()

    def set_mcp(self, enabled):
        self.select_mcp(self.session, enabled)
        with self.app.api(
            f"/sessions/{self.session}/reload", {"target": "session"}
        ) as response:
            return json.load(response)

    def turn(self, prompt, session=None):
        session = session or self.session
        before = len(self.provider.requests)
        self.app.prompt(session, prompt).close()
        self.app.idle(session, timeout=60)
        return [entry["request"] for entry in self.provider.requests[before:]]

    def test_cold_command_and_recorded_recovery_do_not_block_another_session(self):
        other = self.app.session()
        for session, enabled in ((self.session, True), (other, False)):
            route = f"/sessions/{session}?view=configuration"
            with self.app.api(route) as response:
                json.load(response)
                etag = response.headers["ETag"]
            self.app.api(
                route,
                {"selection": {"extensions": {"mcp": enabled}}},
                method="PATCH",
                headers={"If-Match": etag},
            ).close()
        with self.app.api(f"/sessions/{self.session}?tail=0") as response:
            self.assertEqual(json.load(response)["kernel"]["state"], "none")
        marker = self.app.workspace / "cold-mcp-started"
        gate = self.app.workspace / "cold-mcp-release"
        os.mkfifo(gate)
        script = (
            "import pathlib; "
            + f"pathlib.Path({str(marker)!r}).touch(); "
            + f"open({str(gate)!r}, 'rb').read(1); "
            + f"exec(pathlib.Path({str(SERVER)!r}).read_text())"
        )
        self.configure(self.app, ["-c", script], startup=30000)
        input_id = operation_id()

        def submit_command():
            with self.app.api(
                f"/sessions/{self.session}/inputs/{input_id}",
                {
                    "kind": "command",
                    "command_id": "/research",
                    "arguments": {"arguments": "cold composition fixture"},
                },
                method="PUT",
            ) as response:
                return json.load(response)

        def release_preparation():
            deadline = time.monotonic() + 10
            while True:
                try:
                    descriptor = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
                    break
                except OSError as error:
                    if error.errno != errno.ENXIO or time.monotonic() >= deadline:
                        raise
                    time.sleep(0.01)
            try:
                os.write(descriptor, b"x")
            finally:
                os.close(descriptor)

        def complete_independent_turn():
            with self.app.api(f"/sessions/{other}?tail=0") as response:
                self.assertEqual(json.load(response)["id"], other)
            with self.app.prompt(other, "independent turn") as response:
                other_input = json.load(response)["id"]
            self.app.idle(other)
            with self.app.api(f"/sessions/{other}/inputs/{other_input}") as response:
                self.assertEqual(json.load(response)["turn"]["state"], "completed")

        with ThreadPoolExecutor(max_workers=2) as pool:
            command = pool.submit(submit_command)
            deadline = time.monotonic() + 10
            while not marker.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(marker.exists(), "cold MCP preparation did not start")
            try:
                complete_independent_turn()
                self.assertFalse(command.done(), "command passed the held preparation")
            finally:
                release_preparation()
            self.assertEqual(command.result(timeout=40)["id"], input_id)
        self.app.idle(self.session)
        with self.app.api(f"/sessions/{self.session}/inputs/{input_id}") as response:
            self.assertEqual(json.load(response)["turn"]["state"], "completed")
        with self.app.api(f"/sessions/{self.session}?tail=0") as response:
            original_kernel = json.load(response)["kernel"]["instance_id"]
        self.assertIsNotNone(original_kernel)
        original_history = self.app.history(self.session)["items"]
        marker.unlink()
        self.app.restart()
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists(), "recorded kernel preparation did not start")
        try:
            complete_independent_turn()
        finally:
            release_preparation()
        deadline = time.monotonic() + 20
        while True:
            with self.app.api(f"/sessions/{self.session}?tail=0") as response:
                recovered = json.load(response)["kernel"]
            if recovered["state"] == "attached" or time.monotonic() >= deadline:
                break
            time.sleep(0.01)
        self.assertEqual(recovered["state"], "attached")
        self.assertEqual(recovered["instance_id"], original_kernel)
        self.assertEqual(self.app.history(self.session)["items"], original_history)

    def test_discovery_namespaced_call_and_scrubbed_credentials(self):
        self.assertEqual(self.set_mcp(True)["session"]["state"], "applied")
        self.assertTrue(self.mcp()["effective_enabled"])
        self.assertEqual(self.mcp()["extension"]["plugins"], ["managed"])
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

    def test_a_failed_tool_call_is_refused_without_ending_the_turn(self):
        self.set_mcp(True)
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

    def test_disable_closes_server_and_removes_tools(self):
        self.set_mcp(True)
        self.assertEqual(self.set_mcp(False)["session"]["state"], "applied")
        self.assertFalse(self.mcp()["effective_enabled"])
        closed = self.app.root / "closed"
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not closed.exists():
            time.sleep(0.05)
        self.assertTrue(closed.exists(), "disabling must close the server")
        requests = self.turn("the server is gone")
        self.assertFalse(
            any(tool["name"].startswith("mcp_") for tool in requests[0]["tools"])
        )

    def test_insecure_credentials_fail_closed(self):
        credentials = self.app.home / "creds.json"
        credentials.chmod(0o644)
        self.addCleanup(credentials.chmod, 0o600)
        outcome = self.set_mcp(True)
        self.assertEqual(outcome["session"]["state"], "failed")
        self.assertIn("0600", outcome["session"]["failure"]["detail"])
        self.assertFalse(self.provider.requests)
        credentials.chmod(0o600)
        self.assertEqual(self.set_mcp(True)["session"]["state"], "applied")

    def test_an_unavailable_server_is_skipped_and_the_rest_load(self):
        path = self.app.home / "extensions.json"
        settings = json.loads(path.read_text())
        settings["mcp"]["servers"]["dead"] = {
            "type": "stdio",
            "command": str(self.app.root / "missing-server"),
            "startupTimeoutMs": 3000,
        }
        path.write_text(json.dumps(settings))
        self.assertEqual(self.set_mcp(True)["session"]["state"], "applied")
        advertised = self.tools(self.turn("one server is down"))
        self.assertEqual(len(advertised), 1)
        self.assertTrue(advertised[0].startswith("mcp_fake_echo_"))

    def test_a_server_that_comes_online_joins_the_session_after_a_turn(self):
        late = self.app.root / "late_server.py"
        self.configure(self.app, [str(late)], startup=3000, retry=200)
        self.assertEqual(self.set_mcp(True)["session"]["state"], "applied")
        self.assertEqual(self.tools(self.turn("nothing is up yet")), [])
        shutil.copy(SERVER, late)
        deadline = time.monotonic() + 40
        advertised = []
        while time.monotonic() < deadline and not advertised:
            time.sleep(0.5)
            advertised = self.tools(self.turn("is it up now?"))
        self.assertEqual(len(advertised), 1, "the server never joined the session")
        self.assertTrue(advertised[0].startswith("mcp_fake_echo_"))
        history = json.dumps(self.app.history(self.session))
        self.assertIn("capabilities changed", history)
        self.assertIn("fake", history)

    def test_a_known_server_does_not_hold_up_opening_a_session(self):
        self.set_mcp(True)
        self.assertEqual(len(self.tools(self.turn("learn the catalogue"))), 1)
        (self.app.root / "control" / "delay").write_text("3")

        session = self.app.session()
        self.select_mcp(session, True)
        started = time.monotonic()
        with self.app.api(
            f"/sessions/{session}/reload", {"target": "session"}
        ) as response:
            self.assertEqual(json.load(response)["session"]["state"], "applied")
        self.assertLess(time.monotonic() - started, 1.5)

        # The saved tools are advertised at once; the call waits for the dial.
        requests = self.turn("use the mcp server", session)
        self.assertEqual(len(self.tools(requests)), 1)
        output = next(
            item["output"]
            for item in requests[-1]["input"]
            if item.get("type") == "function_call_output"
        )
        self.assertIn(self.message, output)
        self.assertNotIn("capabilities changed", json.dumps(self.app.history(session)))

    def test_a_changed_catalogue_refreshes_the_session_after_its_turn(self):
        self.set_mcp(True)
        self.turn("learn the catalogue")
        schema = {
            "type": "object",
            "required": ["message"],
            "properties": {"message": {"type": "string"}},
        }
        tools = [
            {"name": name, "description": name, "inputSchema": schema}
            for name in ("echo", "shout")
        ]
        (self.app.root / "control" / "tools").write_text(json.dumps(tools))

        session = self.app.session()
        self.select_mcp(session, True)
        self.assertEqual(
            len(self.tools(self.turn("still the saved tools", session))), 1
        )
        deadline = time.monotonic() + 20
        while "capabilities changed" not in json.dumps(self.app.history(session)):
            self.assertLess(time.monotonic(), deadline, "the session never refreshed")
            time.sleep(0.1)
        advertised = self.tools(self.turn("now the new ones", session))
        self.assertEqual(len(advertised), 2)
        self.assertTrue(any(name.startswith("mcp_fake_shout_") for name in advertised))
