"""Real daemon MCP extension: stdio discovery, namespaced calls, env scrubbing, teardown.

The fake server speaks line-delimited JSON-RPC over a real subprocess, so this
exercises the actual client library and launcher instead of a stub inside the daemon.
"""
import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
SERVER = Path(__file__).resolve().parent/"fake_mcp_server.py"


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(request)
        tools = sorted(tool["name"] for tool in request.get("tools", []))
        answered = any(item.get("type") == "function_call_output" for item in request["input"])
        mcp_tool = next((name for name in tools if name.startswith("mcp_")), None)
        if mcp_tool and not answered:
            output = [{"type": "function_call", "id": "fc1", "call_id": "call-mcp",
                       "name": mcp_tool, "arguments": json.dumps({"message": "ping from albedo"}),
                       "status": "completed"}]
        else:
            output = [{"type": "message", "role": "assistant", "status": "completed",
                       "content": [{"type": "output_text", "text": "done", "annotations": []}]}]
        body = ("data: " + json.dumps({"type": "response.completed", "response": {
            "id": "fixture", "status": "completed", "output": output,
            "usage": {"input_tokens": 12, "output_tokens": 1},
        }}) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-mcp-") as directory:
        root = Path(directory)
        home, workspace, user_home = root/"state", root/"workspace", root/"user"
        for path in (home, workspace, user_home):
            path.mkdir(mode=0o700)
        closed = root/"closed"
        (home/"config.json").write_text(json.dumps({"active": "fixture", "providers": {"fixture": {
            "baseUrl": endpoint, "apiKey": "fixture-key", "model": "fixture", "protocol": "responses",
        }}}))

        def configure(args, startup=20000):
            (home/"extensions.json").write_text(json.dumps({"mcp": {"servers": {"fake": {
                "type": "stdio", "command": sys.executable, "args": args,
                "env": {"FAKE_SECRET": {"env": "ALBEDO_MCP_SECRET"},
                        "FAKE_MCP_CLOSED": {"env": "ALBEDO_MCP_CLOSED"}},
                "startupTimeoutMs": startup,
            }}}}))

        configure([str(SERVER)])
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home),
                   ALBEDO_MCP_SECRET="configured-secret", ALBEDO_MCP_CLOSED=str(closed),
                   ALBEDO_MCP_AMBIENT="must-not-reach-the-server")
        connection = None

        def cli(*args):
            result = subprocess.run(["node", "cli/bin/albedo.mjs", *args], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stdout + result.stderr + (home/"daemon.log").read_text()
            return result.stdout

        def api(path, data=None):
            request = urllib.request.Request(f"http://127.0.0.1:{connection['port']}" + path,
                headers={"Authorization": "Bearer " + connection["token"], "Content-Type": "application/json"},
                data=None if data is None else json.dumps(data).encode())
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)

        def ready(session):
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                if not api(f"/sessions/{session}/status")["running"]:
                    return
                time.sleep(.025)
            raise AssertionError("session did not settle: " + (home/"daemon.log").read_text())

        def turn(session, prompt):
            before = len(Provider.requests)
            api(f"/sessions/{session}/events", {"content": prompt})
            ready(session)
            return Provider.requests[before:]

        try:
            cli("sessions")
            connection = json.loads((home/"daemon.json").read_text())
            session = json.loads(cli("new", str(workspace)))["session"]
            route = f"/sessions/{session}/extensions"
            enabled = api(route, {"name": "mcp", "enabled": True})
            mcp = next(item for item in enabled if item["name"] == "mcp")
            assert mcp["enabled"] and mcp["plugins"] == ["managed"], mcp

            requests = turn(session, "use the mcp server")
            assert len(requests) == 2, requests
            context = "\n".join(item["content"] for item in requests[0]["input"]
                                if isinstance(item.get("content"), str)
                                and item["content"].startswith("<extension-context"))
            assert "name=\"mcp\"" in context and "echo" in context, context
            advertised = [tool["name"] for tool in requests[0]["tools"] if tool["name"].startswith("mcp_")]
            assert len(advertised) == 1 and advertised[0].startswith("mcp_fake_echo_"), advertised
            result = next(item["output"] for item in requests[1]["input"]
                          if item.get("type") == "function_call_output")
            assert json.loads(json.loads(result)["content"][0]["text"]) == {
                "echoed": "ping from albedo", "secret": "configured-secret", "ambient": None}, result
            summary = next(item for item in api(route) if item["name"] == "mcp")
            assert summary["tools"] == advertised, summary

            disabled = api(route, {"name": "mcp", "enabled": False})
            assert not next(item["enabled"] for item in disabled if item["name"] == "mcp")
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline and not closed.exists():
                time.sleep(.05)
            assert closed.exists(), "disabling mcp must close its server process"
            requests = turn(session, "the server is gone")
            assert not any(tool["name"].startswith("mcp_") for tool in requests[0]["tools"]), requests[0]["tools"]

            # An unavailable server fails the replacement instead of silently
            # dropping capabilities from a live session.
            configure([str(root/"missing.py")], startup=3000)
            try:
                api(route, {"name": "mcp", "enabled": True})
                raise AssertionError("an unavailable MCP server must not enable")
            except urllib.error.HTTPError as error:
                assert error.code == 409, error.read()
            assert not next(item["enabled"] for item in api(route) if item["name"] == "mcp")
            print("mcp discovery, namespaced calls, env scrubbing, and teardown passed")
        finally:
            if connection:
                with contextlib.suppress(Exception):
                    api("/shutdown", {})


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        run(f"http://127.0.0.1:{server.server_port}/v1")
    finally:
        server.shutdown()
