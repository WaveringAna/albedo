"""The agents and mail python API end-to-end, through a real kernel.

The model in the lead session spawns a child from python. The child reads
who it is from its context, reports progress, is refused when it tries to
cancel its parent, and answers with mail.submit("parent", ...). The answer
starts the lead's next turn, and no unreviewed forward follows.
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



LEAD = """m = await agents.models()
assert "beta/fixture-beta" in m, m
kid = await agents.self.spawn("count to three", name="scout", model=m[0])
try:
    await agents.self.spawn("again", name="scout2", model="")
except TypeError as e:
    print("EMPTY_MODEL", e)
print("SPAWNED", kid.name, kid.depth, kid.parent.name)
"""

CHILD = """me = agents.self
print("ME", me.name, me.depth, me.parent.name)
print("PROGRESS", await agents.progress("counting"))
try:
    await me.parent.cancel()
except AgentsError as e:
    print("REFUSED", e)
try:
    await me.parent.delete()
except AgentsError as e:
    print("ASK", e)
r = await mail.submit("parent", "three")
print("SENT", r.status, r.name)
"""


class Provider(http.server.BaseHTTPRequestHandler):
    """Lead spawns from python; the child answers by mail; everyone else talks."""
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        messages = request["messages"]
        last = messages[-1] if messages else {}
        latest_user = next((content_text(m) for m in reversed(messages) if m.get("role") == "user"), "")
        system = " ".join(content_text(m) for m in messages if m.get("role") != "tool")
        with self.lock:
            self.requests.append({"latest_user": latest_user, "system": system,
                                  "tool": content_text(last) if last.get("role") == "tool" else None})
        code = None
        if last.get("role") == "user" and "spawn a scout" in latest_user:
            code = LEAD
        elif last.get("role") == "user" and 'kind="task"' in latest_user:
            code = CHILD
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
        try:
            if code:
                arguments = json.dumps({"code": code, "timeout_ms": 60000})
                call = {"index": 0, "id": "call-1", "type": "function",
                        "function": {"name": "python", "arguments": arguments}}
                event({"id": "r", "choices": [{"index": 0, "delta": {"tool_calls": [call]}, "finish_reason": None}]})
                event({"id": "r", "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}]})
            else:
                event({"id": "r", "choices": [{"index": 0, "delta": {"content": "ok"}, "finish_reason": None}]})
                event({"id": "r", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-agents-py-") as directory:
        home = Path(directory) / "home"
        workspace = Path(directory) / "workspace"
        home.mkdir(mode=0o700)
        workspace.mkdir()
        (home / "extensions.json").write_text(json.dumps({"models": {"refreshHours": 0}}))
        (home / "config.json").write_text(json.dumps({
            "active": "alpha",
            "providers": {
                "alpha": {"baseUrl": endpoint + "/alpha/v1", "apiKey": "key",
                          "model": "fixture-alpha", "protocol": "chat_completions"},
                "beta": {"baseUrl": endpoint + "/beta/v1", "apiKey": "key",
                         "model": "fixture-beta", "protocol": "chat_completions"},
            },
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
                                   env=env, text=True, capture_output=True, timeout=45)
            assert first.returncode == 0, first.stdout + first.stderr
            connection = json.loads((home / "daemon.json").read_text())
            base = f"http://127.0.0.1:{connection['port']}"
            headers = {"Authorization": "Bearer " + connection["token"],
                       "Content-Type": "application/json"}

            def api(path, body=None):
                req = urllib.request.Request(base + path, headers=headers,
                                             data=None if body is None else json.dumps(body).encode())
                with urllib.request.urlopen(req, timeout=15) as response:
                    return json.load(response)

            def seen():
                with Provider.lock:
                    return list(Provider.requests)

            def wait_for(predicate, what, timeout=60):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.1)
                raise AssertionError(f"never saw {what}: {json.dumps(seen(), indent=1)[:4000]}")

            def tool_output(marker):
                return next((r["tool"] for r in seen() if r["tool"] and marker in r["tool"]), None)

            lead = json.loads(subprocess.run(
                [str(ROOT / "cli/bin/albedo"), "new", str(workspace)], cwd=ROOT, env=env,
                text=True, capture_output=True, timeout=45, check=True).stdout)["session"]
            api(f"/sessions/{lead}/events", {"content": "spawn a scout"})

            wait_for(lambda: tool_output("SPAWNED"), "the lead's spawn")
            spawned = tool_output("SPAWNED")
            assert "SPAWNED scout 1" in spawned, spawned
            assert "EMPTY_MODEL" in spawned, spawned

            wait_for(lambda: tool_output("SENT"), "the child's python")
            child = tool_output("SENT")
            assert "ME scout 1" in child, child
            assert "PROGRESS True" in child, child
            assert "REFUSED" in child and "own children" in child, child
            assert "ASK" in child and "only the user deletes" in child, child
            assert "SENT delivered spawn a scout" in child or "SENT queued spawn a scout" in child, child
            task_request = next(r for r in seen() if 'kind="task"' in r["latest_user"])
            assert 'You are child agent "scout"' in task_request["system"], "the child's context names who it is"

            # The answer starts the lead's turn, and nothing is forwarded after it.
            wait_for(lambda: any('kind="message"' in r["latest_user"] and "three" in r["latest_user"]
                                 for r in seen()), "the answer reaching the lead")
            time.sleep(3)
            assert not any('kind="unreviewed"' in r["latest_user"] for r in seen()), \
                "a child that answered must not be forwarded"
            print("python spawn, family, refusals, progress, and mail.submit answer hold")
        finally:
            if connection:
                with contextlib.suppress(Exception):
                    api("/shutdown", {})
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
    finally:
        server.shutdown()
