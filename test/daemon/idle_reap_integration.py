"""A detached session loses its kernel, keeps its variables, and says so.

Runs the daemon with a ten second idle limit; the shipped default is 31 minutes.
"""

import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
IDLE_SECONDS = 10


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
            if prompt.startswith("remember"):
                code = "answer = 7\nrows = [1, 2, 3]\n"
            elif prompt.startswith("recall"):
                code = "print('recalled', answer, rows)"
        output = [{"type": "message", "role": "assistant", "status": "completed",
                   "content": [{"type": "output_text", "text": "ok", "annotations": []}]}]
        if code:
            output = [{"type": "function_call", "id": "fc-" + str(len(self.requests)),
                       "call_id": "call-" + str(len(self.requests)), "name": "python", "status": "completed",
                       "arguments": json.dumps({"code": code, "timeout_ms": 5000})}]
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


def kernels(daemon_pid):
    """Kernels this daemon owns. They are grandchildren: the runtime spawns ports
    through a helper, and another daemon's kernels are not ours to count."""
    listing = subprocess.run(["ps", "-o", "pid=,ppid=,command=", "-ax"], capture_output=True, text=True)
    processes = {}
    for line in listing.stdout.splitlines():
        fields = line.split(maxsplit=2)
        if len(fields) == 3 and fields[0].isdigit() and fields[1].isdigit():
            processes[int(fields[0])] = (int(fields[1]), fields[2])
    owned, frontier = [], [daemon_pid]
    while frontier:
        parent = frontier.pop()
        for pid, (ppid, command) in processes.items():
            if ppid != parent:
                continue
            frontier.append(pid)
            if "albedo_kernel.py" in command:
                owned.append(pid)
    return owned


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-idle-reap-test-") as directory:
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
        env = dict(os.environ, ALBEDO_HOME=str(home), ALBEDO_PARENT_PID=str(os.getpid()), ALBEDO_IDLE_SECONDS=str(IDLE_SECONDS))
        connection = None

        def cli(*args):
            result = subprocess.run([str(ROOT / "cli/bin/albedo"), *args], cwd=ROOT,
                                    env=env, text=True, capture_output=True, timeout=45)
            assert result.returncode == 0, result.stdout + result.stderr
            return result.stdout

        def api(path, body=None):
            request = urllib.request.Request(
                f"http://127.0.0.1:{connection['port']}" + path,
                headers={"Authorization": "Bearer " + connection["token"],
                         "Content-Type": "application/json"},
                data=None if body is None else json.dumps(body).encode())
            return urllib.request.urlopen(request, timeout=15)

        def ready(session_id):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                with api(f"/sessions/{session_id}/status") as response:
                    if not json.load(response)["running"]:
                        return
                time.sleep(0.05)
            raise AssertionError("session did not settle")

        def events(session_id):
            # From sequence zero: notes live in the session's event ring. A client
            # with no cursor is served the transcript rebuilt from the database.
            with api(f"/sessions/{session_id}/stream?after_seq=0") as response:
                while line := response.readline():
                    if line.startswith(b"data: "):
                        return json.loads(line[6:])["events"]
            raise AssertionError("stream ended without a snapshot")

        try:
            cli("sessions")
            connection = json.loads((home / "daemon.json").read_text())
            daemon = connection["pid"]

            # A restored session costs nothing until it runs something.
            session_id = json.loads(cli("new", str(workspace)))["session"]
            assert kernels(daemon) == [], "a new session opened a kernel before running anything"

            with api(f"/sessions/{session_id}/events", {"content": "remember this"}):
                pass
            ready(session_id)
            assert len(kernels(daemon)) == 1, "running a cell did not open exactly one kernel"

            # Nothing is attached, so the kernel goes once the limit passes.
            deadline = time.monotonic() + IDLE_SECONDS * 4
            while time.monotonic() < deadline and kernels(daemon):
                time.sleep(0.5)
            assert kernels(daemon) == [], "idle kernel outlived its limit"

            note = [event for event in events(session_id) if event.get("type") == "note"]
            assert note and "released" in note[-1]["text"], note
            assert "2 variables saved to disk" in note[-1]["text"], note[-1]["text"]
            assert (home / "kernels" / f"{session_id}.state").exists(), "no state file was written"

            # Reattaching revives the variables and tells the model what came back.
            with api(f"/sessions/{session_id}/events", {"content": "recall them"}):
                pass
            ready(session_id)
            prompt = latest_user(Provider.requests[-1])
            assert prompt.startswith("recall them<system-note>"), prompt
            assert "restored from disk: answer, rows" in prompt, prompt
            assert any("recalled 7 [1, 2, 3]" in item.get("output", "")
                       for item in Provider.requests[-1]["input"]), "restored variables were not usable"

            texts = [event["text"] for event in events(session_id) if event.get("type") == "note"]
            assert any("restored 2 variables from disk" in text for text in texts), texts
        finally:
            if connection:
                with contextlib.suppress(Exception):
                    api("/shutdown", {}).close()
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    try:
                        os.kill(connection["pid"], 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                else:
                    os.kill(connection["pid"], 9)


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        run(f"http://127.0.0.1:{server.server_port}/v1")
        print("idle reap and state restore integration passed")
    finally:
        server.shutdown()
