"""A background job wakes an idle session end-to-end, through the real daemon.

The fake provider answers the first turn with a python tool call that starts a
job and returns, answers the second with plain text so the run ends, and then
must be asked a third time: the job finishing with its result unread submits
the wake turn through the kernel's jobs route, the registry, and the session
actor's registered submit closure. One provider protocol: the wake sits below
that layer, and integration.py owns protocol coverage.
"""
import contextlib
import glob
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


def toolchain_path():
    """gleam and erlang when they only exist as nix store results."""
    entries = ["/nix/store/*gleam*/bin", "/nix/store/*erlang*/bin"]
    found = [path for pattern in entries for path in glob.glob(pattern)]
    return ":".join(found)


TOOLCHAIN = toolchain_path()

def content_text(item):
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(part["text"] for part in content
                        if isinstance(part, dict) and isinstance(part.get("text"), str))
    return ""


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        inputs = request["messages"]
        tool_turns = sum(item.get("role") == "tool" or item.get("type") == "function_call_output"
                         for item in inputs)
        tool_turns = sum(item.get("role") == "tool" or item.get("type") == "function_call_output"
                         for item in inputs)
        latest_user = next((content_text(item) for item in reversed(inputs)
                            if item.get("role") == "user"), "")
        with self.lock:
            self.requests.append({"request": request, "latest_user": latest_user})
        # A fresh user request starts a job; the tool turn after it and the wake
        # turn (whose user message is the notice) both end the run.
        last = inputs[-1] if inputs else {}
        starts = last.get("role") == "user" and "start a slow job" in latest_user
        done = not starts
        sleep = "20" if "detached" in latest_user else "1.2"
        code = f'job = bash("sleep {sleep}; echo wake-done")\njob.id'
        call_id = f"call-{tool_turns + 1}"
        arguments = json.dumps({"code": code, "timeout_ms": 60000})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
        try:
            if not done:
                for i in range(0, len(arguments), 20):
                    function = {"arguments": arguments[i:i+20]}
                    call = {"index": 0, "function": function}
                    if i == 0:
                        function["name"] = "python"
                        call.update(id=call_id, type="function")
                    event({"id": "r1", "choices": [{"index": 0, "delta": {"tool_calls": [call]},
                                                    "finish_reason": None}]})
                event({"id": "r1", "choices": [{"index": 0, "delta": {},
                                                "finish_reason": "tool_calls"}]})
            else:
                event({"id": "r2", "choices": [{"index": 0, "delta": {"content": "finished"},
                                                "finish_reason": None}]})
                event({"id": "r2", "choices": [{"index": 0, "delta": {},
                                                "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-wake-e2e-") as directory:
        home = Path(directory) / "home"
        workspace = Path(directory) / "workspace"
        home.mkdir(mode=0o700)
        workspace.mkdir()
        (home / "extensions.json").write_text(json.dumps({"models": {"refreshHours": 0}}))
        (home / "config.json").write_text(json.dumps({
            "active": "alpha",
            "providers": {"alpha": {"baseUrl": endpoint + "/alpha/v1", "apiKey": "key",
                                     "model": "fixture-alpha", "protocol": "chat_completions"}},
        }))
        env = dict(os.environ, HOME=str(Path(directory) / "user-home"), ALBEDO_HOME=str(home), ALBEDO_PARENT_PID=str(os.getpid()),
                   ALBEDO_IDLE_SECONDS="10")
        import shutil
        if TOOLCHAIN and shutil.which("gleam") is None:
            env["PATH"] = TOOLCHAIN + ":" + env.get("PATH", "")
        for obsolete in ("ALBEDO_API_KEY", "ALBEDO_BASE_URL", "ALBEDO_MODEL", "ALBEDO_PROTOCOL"):
            env.pop(obsolete, None)
        connection = None
        requests_at_start = len(Provider.requests)
        try:
            first = subprocess.run(["node", "cli/bin/albedo.mjs", "sessions"], cwd=ROOT,
                                   env=env, text=True, capture_output=True, timeout=45)
            assert first.returncode == 0, first.stdout + first.stderr
            connection = json.loads((home / "daemon.json").read_text())
            base = f"http://127.0.0.1:{connection['port']}"
            headers = {"Authorization": "Bearer " + connection["token"],
                       "Content-Type": "application/json"}

            def api(path, body=None):
                req = urllib.request.Request(base + path, headers=headers,
                                             data=None if body is None else json.dumps(body).encode())
                return urllib.request.urlopen(req, timeout=15)

            def seen():
                with Provider.lock:
                    return Provider.requests[requests_at_start:]

            def status(session_id):
                with api(f"/sessions/{session_id}/status") as response:
                    return json.load(response)

            def settle(session_id, timeout=30):
                deadline = time.monotonic() + timeout
                value = None
                while time.monotonic() < deadline:
                    value = status(session_id)
                    if not value["running"]:
                        return value
                    time.sleep(0.05)
                raise AssertionError(f"session never settled: {value}")

            created = json.loads(subprocess.run(
                ["node", "cli/bin/albedo.mjs", "new", str(workspace)], cwd=ROOT, env=env,
                text=True, capture_output=True, timeout=45, check=True).stdout)
            session_id = created["session"]
            with api(f"/sessions/{session_id}/events", {"content": "start a slow job"}):
                pass
            settle(session_id)
            assert len(seen()) == 2, [r["latest_user"] for r in seen()]

            def stream(query):
                with api(f"/sessions/{session_id}/stream{query}") as response:
                    while True:
                        line = response.readline()
                        if line.startswith(b"data: "):
                            return json.loads(line[6:])

            # A cursor before the wake; the live event keeps its source.
            before = stream("?after_seq=-1")
            # The job outlives the run; its completion must submit a wake turn.
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                if len(seen()) >= 3:
                    break
                time.sleep(0.1)
            settle(session_id)
            assert len(seen()) == 3, [r["latest_user"] for r in seen()]
            wake = seen()[2]["latest_user"]
            assert "background bash job finished" in wake, wake
            assert "jobs[" in wake and "output.read" in wake, wake

            live = stream(f"?after_seq={before['cursor']}")["events"]
            live_wake = [e for e in live
                         if e.get("type") == "user" and "bash job finished" in e.get("text", "")]
            assert len(live_wake) == 1, [e.get("type") for e in live]
            assert live_wake[0]["source"] == "bash", live_wake[0]
            assert live_wake[0]["clientId"] == "bash", live_wake[0]
            assert "exit_code=0" in live_wake[0]["text"], live_wake[0]

            # The durable snapshot renders user turns uniformly, so the wake is
            # identified by its text there; the provider request already proved it ran.
            durable = [e for e in stream("?after_seq=-1")["events"]
                       if e.get("type") == "user" and "bash job finished" in e.get("text", "")]
            assert len(durable) == 1, "the wake turn did not commit durably"

            # No further wake: the notice was delivered once.
            time.sleep(2.5)
            assert len(seen()) == 3, [r["latest_user"] for r in seen()]

            # A detached idle session keeps its kernel while a job runs: without
            # the live-job pin, the 10-second idle sweep would release the kernel
            # and kill the 20-second job before it could wake anyone.
            with api(f"/sessions/{session_id}/events",
                     {"content": "start a slow job, detached"}) as response:
                response.read()
            settle(session_id)
            assert len(seen()) == 5, [r["latest_user"] for r in seen()]
            deadline = time.monotonic() + 50
            while time.monotonic() < deadline:
                if len(seen()) >= 6:
                    break
                time.sleep(0.2)  # no daemon contact: the session stays detached
            settle(session_id)
            assert len(seen()) == 6, [r["latest_user"] for r in seen()]
            assert "background bash job finished" in seen()[5]["latest_user"], seen()[5]
            print("background job wake delivered a turn, once, and survived an idle detach")
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
        # One protocol: the wake sits below the provider layer, and
        # integration.py owns projected history for both protocols.
        run(f"http://127.0.0.1:{server.server_port}/v1")
    finally:
        server.shutdown()
