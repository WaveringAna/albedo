"""Isolated daemon integration test for one-shot Python reset notices."""

import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
NOTICE = "<system-note>The python kernel got reset and all variables are lost</system-note>"


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.lock:
            self.requests.append(request)
        prompt = latest_user(request)
        code = None
        if request["input"][-1].get("role") == "user":
            if prompt == "lose kernel":
                code = "import os; os._exit(1)"
            elif prompt == "recover kernel" + NOTICE:
                code = "print('kernel-ready')"
        output = [{"type": "message", "role": "assistant", "status": "completed",
                   "content": [{"type": "output_text", "text": "ok", "annotations": []}]}]
        if code:
            output = [{"type": "function_call", "id": "fc-" + str(len(self.requests)),
                       "call_id": "call-" + str(len(self.requests)), "name": "python", "status": "completed",
                       "arguments": json.dumps({"code": code, "timeout_ms": 1000})}]
        body = ("data: " + json.dumps({"type": "response.completed", "response": {
            "id": "response", "status": "completed", "output": output,
        }}) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def latest_user(request):
    return [item["content"] for item in request["input"] if item.get("role") == "user"][-1]


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-kernel-reset-test-") as directory:
        home = Path(directory) / "home"
        workspace = Path(directory) / "workspace"
        home.mkdir(mode=0o700)
        workspace.mkdir()
        (home / "config.json").write_text(json.dumps({
            "active": "test",
            "providers": {"test": {
                "baseUrl": endpoint,
                "apiKey": "fixture-key",
                "model": "fixture-model",
                "protocol": "responses",
            }},
        }))
        env = dict(os.environ, ALBEDO_HOME=str(home), ALBEDO_PARENT_PID=str(os.getpid()))
        connection = None

        def command(*args):
            return subprocess.run(
                ["node", "cli/bin/albedo.mjs", *args],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                timeout=45,
            )

        def cli(*args):
            result = command(*args)
            assert result.returncode == 0, result.stdout + result.stderr
            return result.stdout

        def reconnect():
            nonlocal connection, base
            cli("sessions")
            connection = json.loads((home / "daemon.json").read_text())
            base = f"http://127.0.0.1:{connection['port']}"

        def api(path, body=None):
            request = urllib.request.Request(
                base + path,
                headers={
                    "Authorization": "Bearer " + connection["token"],
                    "Content-Type": "application/json",
                },
                data=None if body is None else json.dumps(body).encode(),
            )
            return urllib.request.urlopen(request, timeout=15)

        def submit(session_id, content):
            return api(f"/sessions/{session_id}/events", {"content": content})

        def ready(session_id):
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                with api(f"/sessions/{session_id}/status") as response:
                    if not json.load(response)["running"]:
                        return
                time.sleep(0.05)
            raise AssertionError("session did not settle")

        def snapshot(session_id):
            with api(f"/sessions/{session_id}/stream") as response:
                while line := response.readline():
                    if line.startswith(b"data: "):
                        return json.loads(line[6:])["events"]
            raise AssertionError("stream ended without a snapshot")

        base = ""
        try:
            reconnect()
            session_id = json.loads(cli("new", str(workspace)))["session"]

            with submit(session_id, "first prompt"):
                pass
            ready(session_id)
            assert latest_user(Provider.requests[-1]) == "first prompt"
            unused_id = json.loads(cli("new", str(workspace)))["session"]

            os.kill(connection["pid"], 9)
            reconnect()

            with submit(unused_id, "unused session's first prompt"):
                pass
            ready(unused_id)
            assert latest_user(Provider.requests[-1]) == "unused session's first prompt"

            try:
                submit(session_id, "   ").close()
                raise AssertionError("blank prompt was accepted")
            except urllib.error.HTTPError as error:
                assert error.code == 409

            with submit(session_id, "after reset"):
                pass
            ready(session_id)
            assert latest_user(Provider.requests[-1]) == "after reset" + NOTICE

            with submit(session_id, "ordinary turn"):
                pass
            ready(session_id)
            assert latest_user(Provider.requests[-1]) == "ordinary turn"

            with submit(session_id, "lose kernel"):
                pass
            ready(session_id)
            assert latest_user(Provider.requests[-1]) == "lose kernel"
            with submit(session_id, "recover kernel"):
                pass
            ready(session_id)
            assert latest_user(Provider.requests[-1]) == "recover kernel" + NOTICE
            assert any("kernel-ready" in item.get("output", "") for item in Provider.requests[-1]["input"])
            with submit(session_id, "still alive"):
                pass
            ready(session_id)
            assert latest_user(Provider.requests[-1]) == "still alive"

            user_texts = [
                event["text"]
                for event in snapshot(session_id)
                if event.get("type") == "user"
            ]
            assert user_texts == ["first prompt", "after reset", "ordinary turn", "lose kernel", "recover kernel", "still alive"]
            with api("/sessions") as response:
                info = next(item for item in json.load(response) if item["id"] == session_id)
            assert info["title"] == "still alive"
        finally:
            if connection:
                pid = connection["pid"]
                with contextlib.suppress(Exception):
                    api("/shutdown", {}).close()
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                else:
                    os.kill(pid, 9)


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        run(f"http://127.0.0.1:{server.server_port}/v1")
        print("kernel reset notice integration passed")
    finally:
        server.shutdown()
