"""Agents and mail end-to-end, through the real daemon.

A parent spawns a child with a task. The child answers in plain text and ends
its run without writing back, so the daemon forwards its last words to the
parent as an unreviewed answer, and that letter starts the parent's next turn.
A follow-up from the parent reaches the child by name, the child's reply by
"parent" wakes the parent without a second forward, a session outside the
family is reached by id, and a parent with children cannot be deleted.
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
    """Answers every request in plain text naming what it was asked."""
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        latest_user = next((content_text(item) for item in reversed(request["messages"])
                            if item.get("role") == "user"), "")
        with self.lock:
            self.requests.append(latest_user)
        answer = "answered: " + latest_user.splitlines()[-2 if "</mail>" in latest_user else -1]
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
        try:
            event({"id": "r", "choices": [{"index": 0, "delta": {"content": answer},
                                           "finish_reason": None}]})
            event({"id": "r", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            self.wfile.write(b"data: [DONE]\n\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-agents-e2e-") as directory:
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
                                   env=env, text=True, capture_output=True, timeout=45)
            assert first.returncode == 0, first.stdout + first.stderr
            connection = json.loads((home / "daemon.json").read_text())
            base = f"http://127.0.0.1:{connection['port']}"
            headers = {"Authorization": "Bearer " + connection["token"],
                       "Content-Type": "application/json"}

            def api(path, body=None, method=None):
                req = urllib.request.Request(base + path, headers=headers, method=method,
                                             data=None if body is None else json.dumps(body).encode())
                with urllib.request.urlopen(req, timeout=15) as response:
                    return json.load(response)

            def new_session():
                created = json.loads(subprocess.run(
                    [str(ROOT / "cli/bin/albedo"), "new", str(workspace)], cwd=ROOT, env=env,
                    text=True, capture_output=True, timeout=45, check=True).stdout)
                return created["session"]

            def seen():
                with Provider.lock:
                    return list(Provider.requests)

            def wait_for(predicate, what, timeout=30):
                deadline = time.monotonic() + timeout
                while time.monotonic() < deadline:
                    if predicate():
                        return
                    time.sleep(0.05)
                raise AssertionError(f"never saw {what}: {seen()}")

            def asked(fragment):
                return [text for text in seen() if fragment in text]

            def settle(session_id):
                wait_for(lambda: not api(f"/sessions/{session_id}/status")["running"],
                         f"{session_id} settle")

            lead = new_session()
            radio = new_session()

            # The orchestrator view's feed: every bus batch, read in the background.
            heard = []

            def listen():
                req = urllib.request.Request(base + "/agents/stream", headers=headers)
                with contextlib.suppress(Exception):
                    with urllib.request.urlopen(req, timeout=120) as response:
                        for raw in response:
                            if raw.startswith(b"data: "):
                                heard.extend(json.loads(raw[6:])["events"])
            threading.Thread(target=listen, daemon=True).start()
            time.sleep(0.5)

            # Spawn: the task reaches the child as a letter from its parent.
            spawned = api(f"/sessions/{lead}/children",
                          {"name": "coder", "task": "map every wake path"})
            coder = spawned["session"]["id"]
            assert spawned["member"] == {"session": coder, "parent": lead, "name": "coder",
                                         "depth": 1, "closed": False}, spawned
            assert spawned["session"]["title"] == "coder", spawned
            listed = [s["id"] for s in api("/sessions")]
            assert lead in listed and coder not in listed, "children stay out of the session list"
            wait_for(lambda: asked('kind="task"'), "the task")
            task = asked('kind="task"')[0]
            assert f'session="{lead}"' in task and "map every wake path" in task, task

            # The child ended without writing back: its last words go up, unreviewed,
            # and start the parent's turn.
            wait_for(lambda: asked('kind="unreviewed"'), "the forwarded answer")
            forwarded = asked('kind="unreviewed"')[0]
            assert 'from="coder"' in forwarded, forwarded
            assert "answered: map every wake path" in forwarded, forwarded
            settle(lead)
            settle(coder)
            assert [m["name"] for m in api(f"/sessions/{lead}/children")] == ["coder"]

            # The snapshot is the whole tree from whichever member asks.
            for asker in (lead, coder):
                tree = api(f"/agents?session={asker}")
                assert tree["root"] == lead, tree
                assert [(n["name"], n["parent"], n["depth"]) for n in tree["nodes"]] == [
                    (tree["nodes"][0]["name"], None, 0), ("coder", lead, 1)], tree
            # The stream flushes every 100 ms, so the last batch may still be on its way.
            def kinds():
                return {(e["type"], e.get("session") or e.get("to")) for e in list(heard)}
            expected = {("spawn", coder), ("mail", coder), ("mail", lead), ("running", coder),
                        ("running", lead), ("text", coder)}
            wait_for(lambda: expected <= kinds(), f"bus events {expected - kinds()}", timeout=10)

            # A follow-up by name, then an explicit reply by "parent".
            receipt = api(f"/sessions/{lead}/mail", {"to": "coder", "body": "also cover schedules"})
            assert receipt["to"] == coder and receipt["name"] == "coder", receipt
            assert receipt["status"] in ("delivered", "queued"), receipt
            wait_for(lambda: asked("also cover schedules"), "the follow-up")
            settle(coder)
            # That run ended without a reply too, so it was forwarded a second time.
            wait_for(lambda: len(asked('kind="unreviewed"')) == 2, "the second forward")
            settle(lead)
            before = len(seen())
            reply = api(f"/sessions/{coder}/mail", {"to": "parent", "body": "schedules covered"})
            assert reply["to"] == lead, reply
            wait_for(lambda: asked("schedules covered"), "the explicit reply")
            settle(lead)
            time.sleep(1)
            # The parent's answer to the reply is its own business: nothing else ran.
            assert len(seen()) == before + 1, seen()[before:]

            # Outside the family, only an id reaches a session.
            with contextlib.suppress(urllib.error.HTTPError):
                api(f"/sessions/{coder}/mail", {"to": "radio", "body": "by name"})
                raise AssertionError("a name outside the family resolved")
            # radio's actor has not started, so the dispatcher's next tick delivers it.
            by_id = api(f"/sessions/{coder}/mail", {"to": radio, "body": "deploy when green"})
            assert by_id["status"] == "pending", by_id
            wait_for(lambda: asked("deploy when green"), "mail by id", timeout=40)
            settle(radio)

            # A parent is deleted after its children, never before.
            try:
                api(f"/sessions/{lead}", method="DELETE")
                raise AssertionError("deleted a parent with a child")
            except urllib.error.HTTPError as error:
                assert error.code == 409, error.code
                assert "child" in error.read().decode(), "refusal should name the children"
            api(f"/sessions/{coder}", method="DELETE")
            api(f"/sessions/{lead}", method="DELETE")
            print("spawn, forwarded answers, mail by name and id, and parent deletion order hold")
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
