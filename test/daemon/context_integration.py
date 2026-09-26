"""Real daemon read-only /context snapshot against an observed provider request."""
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


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    catalog = json.dumps({"fixture-cloud": {
        "id": "fixture-cloud", "name": "Fixture Cloud", "env": ["FIXTURE_API_KEY"],
        "models": {"fixture": {"id": "fixture", "limit": {"context": 200000, "output": 8000},
                               "modalities": {"input": ["text"]}}},
    }})

    def do_GET(self):
        body = self.catalog.encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(request)
        response = {"type": "response.completed", "response": {
            "id": "fixture", "status": "completed", "output": [{
                "type": "message", "role": "assistant", "status": "completed",
                "content": [{"type": "output_text", "text": "done", "annotations": []}],
            }], "usage": {"input_tokens": 20, "output_tokens": 1},
        }}
        if "without provider usage" in json.dumps(request):
            response["response"].pop("usage")
        body = ("data: " + json.dumps(response) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-context-") as directory:
        root = Path(directory)
        home, workspace, user_home = root/"state", root/"workspace", root/"user"
        for path in (home, workspace, user_home):
            path.mkdir(mode=0o700)
        secret = "credential-must-never-appear-in-inspector"
        (home/"config.json").write_text(json.dumps({"active": "fixture", "providers": {"fixture": {
            "baseUrl": endpoint, "apiKey": secret, "model": "fixture", "protocol": "responses",
        }}}))
        # The catalog provider is the same local server, so no test reaches the network.
        (home/"extensions.json").write_text(json.dumps({"models": {
            "url": endpoint.rsplit("/", 1)[0] + "/models.json", "refreshHours": 24,
        }}))
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home), ALBEDO_PARENT_PID=str(os.getpid()))
        connection = None

        def cli(*args):
            result = subprocess.run([str(ROOT / "cli/bin/albedo"), *args], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=45)
            assert result.returncode == 0, result.stdout + result.stderr + (home/"daemon.log").read_text()
            return result.stdout

        def api(path, data=None):
            request = urllib.request.Request(f"http://127.0.0.1:{connection['port']}" + path,
                headers={"Authorization": "Bearer " + connection["token"], "Content-Type": "application/json"},
                data=None if data is None else json.dumps(data).encode())
            with urllib.request.urlopen(request, timeout=25) as response:
                return json.load(response)

        def stop():
            if not connection:
                return
            with contextlib.suppress(Exception):
                api("/shutdown", {})

        try:
            cli("sessions")
            connection = json.loads((home/"daemon.json").read_text())
            assert "session_context" in api("/health")["capabilities"]
            session = json.loads(cli("new", str(workspace)))["session"]
            route = f"/sessions/{session}/context"

            before = api(route)
            assert before == {"state": "pending", "reason": "runtime session has not prepared a provider request"}
            assert Provider.requests == [], "inspection must not contact the provider"

            api(f"/sessions/{session}/events", {"content": "inspect exact composition"})
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and api(f"/sessions/{session}/status")["running"]:
                time.sleep(.025)
            assert len(Provider.requests) == 1
            sent = Provider.requests[0]

            snapshot = api(route)
            assert snapshot["state"] == "ready"
            assert snapshot["provider"] == "fixture" and snapshot["model"] == "fixture"
            # The catalog is stored trimmed to the fields lookup reads.
            served = json.loads(Provider.catalog)["fixture-cloud"]
            assert json.loads((home/"models.json").read_text()) == {"fixture-cloud": {
                "env": served["env"], "models": served["models"]}}
            assert snapshot["context_window_tokens"] == 200_000, snapshot
            compaction = snapshot["compaction"]
            assert compaction["provider_input_tokens"] == 20, compaction
            assert "provider_cached_input_tokens" not in compaction, compaction
            assert compaction["estimate_method"] == "local byte-based estimate; not provider token usage"
            assert compaction["status"] == "not_needed", compaction
            assert compaction["input_limit_tokens"] == 200_000, compaction
            assert compaction["trigger_free_percent"] == 10, compaction
            assert "fixture-cloud" in compaction["source"] and "models.dev catalog" in compaction["source"], compaction
            labels = [section["label"] for section in snapshot["sections"]]
            assert labels[0] == "system instructions" and labels[-2:] == ["prepared conversation", "tool schemas"]
            assert all(label.startswith("extension context · ") for label in labels[1:-2])
            assert all(section["preview"] and len(section["preview"]) <= 180 for section in snapshot["sections"])
            assert secret not in json.dumps(snapshot)

            pages = {}
            for section in snapshot["sections"]:
                first = api(f"{route}/{section['id']}/0")
                parts = [first] + [api(f"{route}/{section['id']}/{n}") for n in range(1, first["pages"])]
                assert all(len(part["content"].encode()) <= 32_000 for part in parts)
                pages[section["id"]] = "".join(part["content"] for part in parts)
            assert pages["instructions"] == sent["instructions"]
            assert json.loads(pages["tools"]) == sent["tools"]
            assert "inspect exact composition" in pages["history"]
            assert secret not in json.dumps(pages)
            assert len(Provider.requests) == 1, "summary/page inspection must not contact the provider"

            api(f"/sessions/{session}/events", {"content": "without provider usage"})
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and api(f"/sessions/{session}/status")["running"]:
                time.sleep(.025)
            unreported = api(route)["compaction"]
            assert "provider_input_tokens" not in unreported, unreported
            assert "estimated_input_tokens" in unreported, unreported

            changed = api(f"/sessions/{session}/commands", {"name": "/model", "args": {"model": "changed-model"}})
            assert changed["result"]["model"] == "changed-model"
            assert api(route) == {
                "state": "pending",
                "reason": "runtime session has not prepared a provider request",
            }, "a snapshot for the old model must not survive model selection"
            assert len(Provider.requests) == 2, "model invalidation must not contact the provider"

            # A model the catalog does not list stays explicitly unknown.
            api(f"/sessions/{session}/events", {"content": "a model outside the catalog"})
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline and api(f"/sessions/{session}/status")["running"]:
                time.sleep(.025)
            unknown = api(route)
            assert "context_window_tokens" not in unknown, unknown
            assert unknown["compaction"]["status"] == "unknown", unknown["compaction"]
            print("context pending/ready sources, exact schema reuse, bounds, read-only behavior, and model invalidation passed")
        finally:
            stop()


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        run(f"http://127.0.0.1:{server.server_port}/v1")
    finally:
        server.shutdown()
