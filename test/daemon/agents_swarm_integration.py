"""A swarm boots at once without taking the daemon down.

Four roots each spawn twelve children, so 52 sessions want a Python kernel at
the same moment. Kernels boot a few at a time off the actors, so every session
stays answerable while it waits: the tree snapshot and each child's status
answer quickly throughout. Every child runs a python cell and ends without
replying, so each root receives one unreviewed answer per child.
"""
import contextlib
import glob
import http.server
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
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
    """A task gets one python cell; everything else gets plain text."""
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        last = messages[-1] if messages else {}
        latest_user = next((content_text(m) for m in reversed(messages) if m.get("role") == "user"), "")
        with self.lock:
            self.requests.append(latest_user)
        tool = last.get("role") == "user" and 'kind="task"' in latest_user
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
        try:
            if tool:
                arguments = json.dumps({"code": "print('cell ran')", "timeout_ms": 60000})
                call = {"index": 0, "id": "call-1", "type": "function",
                        "function": {"name": "python", "arguments": arguments}}
                event({"id": "r", "choices": [{"index": 0, "delta": {"tool_calls": [call]}, "finish_reason": None}]})
                event({"id": "r", "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
            else:
                event({"id": "r", "choices": [{"index": 0, "delta": {"content": "done"}, "finish_reason": None}]})
                event({"id": "r", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


ROOTS, CHILDREN = 4, 12


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-swarm-") as directory:
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
        env = dict(os.environ, HOME=str(Path(directory) / "user-home"), ALBEDO_HOME=str(home),
                   ALBEDO_PARENT_PID=str(os.getpid()))
        if TOOLCHAIN and shutil.which("gleam") is None:
            env["PATH"] = TOOLCHAIN + ":" + env.get("PATH", "")
        for obsolete in ("ALBEDO_API_KEY", "ALBEDO_BASE_URL", "ALBEDO_MODEL", "ALBEDO_PROTOCOL"):
            env.pop(obsolete, None)
        connection = None
        try:
            first = subprocess.run([str(ROOT / "cli/bin/albedo"), "sessions"], cwd=ROOT,
                                   env=env, text=True, capture_output=True, timeout=120)
            assert first.returncode == 0, first.stdout + first.stderr
            connection = json.loads((home / "daemon.json").read_text())
            base = f"http://127.0.0.1:{connection['port']}"
            headers = {"Authorization": "Bearer " + connection["token"],
                       "Content-Type": "application/json"}

            def api(path, body=None, timeout=15):
                req = urllib.request.Request(base + path, headers=headers,
                                             data=None if body is None else json.dumps(body).encode())
                with urllib.request.urlopen(req, timeout=timeout) as response:
                    return json.load(response)

            roots = [json.loads(subprocess.run(
                [str(ROOT / "cli/bin/albedo"), "new", str(workspace)], cwd=ROOT, env=env,
                text=True, capture_output=True, timeout=45, check=True).stdout)["session"]
                for _ in range(ROOTS)]
            children = []
            started = time.monotonic()
            for root in roots:
                for n in range(CHILDREN):
                    made = api(f"/sessions/{root}/children", {"name": f"sp-{n}", "task": f"count to {n}"})
                    children.append(made["session"]["id"])
            spawn_time = time.monotonic() - started
            assert spawn_time < 30, f"spawning {len(children)} children took {spawn_time:.1f}s"

            # While the kernels boot, everything stays answerable.
            slowest, saw_starting = 0.0, False
            deadline = time.monotonic() + 300
            while time.monotonic() < deadline:
                done = [s for s in seen_answers(roots, api)]
                t = time.monotonic()
                for root in roots:
                    api(f"/agents?session={root}", timeout=5)
                for child in children[::6]:
                    status = api(f"/sessions/{child}/status", timeout=5)
                    saw_starting = saw_starting or status.get("phase") == "starting"
                slowest = max(slowest, time.monotonic() - t)
                if sum(done) == ROOTS * CHILDREN:
                    break
                time.sleep(0.5)
            answers = seen_answers(roots, api)
            assert sum(answers) == ROOTS * CHILDREN, f"answers per root: {answers}"
            assert slowest < 5, f"a round of status calls took {slowest:.1f}s"
            assert saw_starting, "no child was ever seen starting its kernel"
            assert api("/health")["ok"], "the daemon must still be up"
            print(f"{len(children)} children booted and answered; status calls stayed under "
                  f"{slowest:.1f}s per round")
        finally:
            if connection:
                with contextlib.suppress(Exception):
                    api("/shutdown", {})
                deadline = time.monotonic() + 20
                while time.monotonic() < deadline:
                    try:
                        os.kill(connection["pid"], 0)
                    except ProcessLookupError:
                        break
                    time.sleep(0.05)
                else:
                    os.kill(connection["pid"], 9)


def seen_answers(roots, api):
    """How many forwarded answers each root has in its transcript."""
    counts = []
    for root in roots:
        items = api(f"/sessions/{root}/preview?limit=200")["items"]
        counts.append(sum(1 for item in items if item["type"] == "user" and "unreviewed" in item["preview"]))
    return counts


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        run(f"http://127.0.0.1:{server.server_port}/v1")
    finally:
        server.shutdown()
