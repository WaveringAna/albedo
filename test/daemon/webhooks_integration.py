"""Signed webhook ingress wakes the same durable session; no live provider."""
import contextlib
import hashlib
import hmac
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(request)
        output = [{"type": "message", "role": "assistant", "status": "completed",
                   "content": [{"type": "output_text", "text": "acknowledged", "annotations": []}]}]
        if (any(item.get("role") == "user" and "probe webhook binding" in str(item.get("content", ""))
                for item in request["input"]) and request["input"][-1].get("type") != "function_call_output"):
            code = ("hooks = await webhooks.list()\n"
                    "assert any(h.name == 'outage' for h in hooks)\n"
                    f"payload = await webhooks.delivery('{self.delivery_id}')\n"
                    "assert 'down' in payload.body\n"
                    "print('WEBHOOK_BINDING_OK')")
            output = [{"type": "function_call", "id": "fc-hook", "call_id": "call-hook",
                       "name": "python", "arguments": json.dumps({"code": code, "timeout_ms": 10000}),
                       "status": "completed"}]
        event = {"type": "response.completed", "response": {
            "id": "fixture", "status": "completed", "output": output,
            "usage": {"input_tokens": 20, "output_tokens": 2},
        }}
        body = ("data: " + json.dumps(event) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def status(call):
    try:
        with call() as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def main():
    provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=provider.serve_forever, daemon=True).start()
    with tempfile.TemporaryDirectory(prefix="albedo-webhooks-") as directory:
        root = Path(directory)
        home, workspace, user_home = root/"state", root/"workspace", root/"user"
        for path in (home, workspace, user_home):
            path.mkdir(mode=0o700)
        (home/"config.json").write_text(json.dumps({"active": "fixture", "providers": {"fixture": {
            "baseUrl": f"http://127.0.0.1:{provider.server_address[1]}/v1", "apiKey": "key",
            "model": "fixture", "protocol": "responses",
        }}}))
        (home/"extensions.json").write_text(json.dumps({"models": {"refreshHours": 0}}))
        port = free_port()
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home), ALBEDO_PORT=str(port),
                   ALBEDO_PARENT_PID=str(os.getpid()), ALBEDO_NO_BROWSER="1")
        connection = None

        def cli(*args):
            result = subprocess.run([str(ROOT/"cli/bin/albedo"), *args], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=45)
            assert result.returncode == 0, result.stdout + result.stderr + (home/"daemon.log").read_text()
            return result.stdout

        def api(path, data=None):
            request = urllib.request.Request(f"http://127.0.0.1:{port}" + path,
                headers={"Authorization": "Bearer " + connection["token"], "Content-Type": "application/json"},
                data=None if data is None else json.dumps(data).encode())
            with urllib.request.urlopen(request, timeout=25) as response:
                return json.load(response)

        try:
            cli("sessions")
            connection = json.loads((home/"daemon.json").read_text())
            session = json.loads(cli("new", str(workspace)))["session"]
            api(f"/sessions/{session}/extensions", {"name": "webhooks", "scope": "global", "enabled": True})
            command = f"/sessions/{session}/commands"
            created = api(command, {"name": "/webhooks", "args": {"action": "create", "details": "outage"}})["result"]
            hook, secret = created["hook"], created["secret"]
            url = f"http://127.0.0.1:{port}" + hook["url"]
            payload = b'{"status":"down"}'
            signature = "sha256=" + hmac.new(secret.encode(), payload, hashlib.sha256).hexdigest()

            def send(body=payload, sig=signature, event_id="alert-1", origin=None):
                headers = {"X-Albedo-Signature": sig, "X-Albedo-Event-Id": event_id}
                if origin:
                    headers["Origin"] = origin
                return urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=25)

            assert status(lambda: send(sig="sha256=wrong")) == 401
            assert status(lambda: send(origin="https://attacker.example")) == 403
            with send() as response:
                delivery = json.load(response)["deliveryId"]
                assert response.status == 202
            with send() as response:
                assert json.load(response)["deliveryId"] == delivery
            assert status(lambda: send(body=b"different", sig="sha256=" + hmac.new(secret.encode(), b"different", hashlib.sha256).hexdigest())) == 409
            deadline = time.monotonic() + 40
            while time.monotonic() < deadline and not Provider.requests:
                time.sleep(.25)
            assert Provider.requests, (home/"daemon.log").read_text()
            assert any("[webhook outage #" in json.dumps(request) for request in Provider.requests)
            assert len(Provider.requests) == 1, "retry should wake the session once"
            assert api(command, {"name": "/webhooks", "args": {"action": "list"}})["result"]["page"]["rows"][0]["id"] == hook["id"]
            api(command, {"name": "/webhooks", "args": {"action": "agent_on"}})
            Provider.delivery_id = delivery
            api(f"/sessions/{session}/events", {"content": "probe webhook binding"})
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and len(Provider.requests) < 3:
                time.sleep(.1)
            assert len(Provider.requests) == 3, (home/"daemon.log").read_text()
            tool_outputs = [item.get("output", "") for item in Provider.requests[-1]["input"]
                            if item.get("type") == "function_call_output"]
            assert any("WEBHOOK_BINDING_OK" in str(output) for output in tool_outputs), tool_outputs
        finally:
            if connection:
                with contextlib.suppress(Exception):
                    api("/shutdown", {})
            provider.shutdown()


if __name__ == "__main__":
    main()
