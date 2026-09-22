"""Real daemon extension selection, context loading, and live reload. No live model."""
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


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []
    entered = threading.Event()
    release = threading.Event()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append(request)
        messages = request["input"]
        prompt = next(item.get("content", "") for item in reversed(messages) if item.get("role") == "user")
        if prompt == "hold this turn":
            self.entered.set()
            assert self.release.wait(15), "test did not release held model request"
        output = [{
            "type": "message", "role": "assistant", "status": "completed",
            "content": [{"type": "output_text", "text": "done", "annotations": []}],
        }]
        if prompt == "activate demo via python" and messages[-1].get("type") != "function_call_output":
            code = "activation = await skills.activate('demo', 'python argument')\nassert 'BODY_MUST_NOT_AUTOLOAD' in activation['instructions']\nassert activation['arguments'] == 'python argument'\nprint('SKILL_PYTHON_ACTIVATION_OK')"
            output = [{"type": "function_call", "id": "fc-skills", "call_id": "call-skills",
                       "name": "python", "arguments": json.dumps({"code": code, "timeout_ms": 10000}),
                       "status": "completed"}]
        response = {"type": "response.completed", "response": {
            "id": "fixture", "status": "completed", "output": output,
            "usage": {"input_tokens": 20, "output_tokens": 1},
        }}
        body = ("data: " + json.dumps(response) + "\n\n").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def run(endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-extensions-") as directory:
        root = Path(directory)
        home, workspace, user_home = root/"state", root/"workspace", root/"user"
        for path in (home, workspace, user_home):
            path.mkdir(mode=0o700)
        skill = workspace/".albedo"/"skills"/"demo"/"SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text("---\nname: demo\ndescription: catalog-only fixture description\n---\nBODY_MUST_NOT_AUTOLOAD\n")
        (home/"config.json").write_text(json.dumps({"active": "fixture", "providers": {"fixture": {
            "baseUrl": endpoint, "apiKey": "fixture-key", "model": "fixture", "protocol": "responses",
        }}}))
        # Catalog refresh is disabled so the suite never reaches the network.
        (home/"extensions.json").write_text(json.dumps({"models": {"refreshHours": 0}}))
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home))
        connection = None

        def cli(*args):
            result = subprocess.run(["node", "cli/bin/albedo.mjs", *args], cwd=ROOT, env=env,
                                    capture_output=True, text=True, timeout=45)
            assert result.returncode == 0, result.stdout + result.stderr + (home/"daemon.log").read_text()
            return result.stdout

        def connect():
            nonlocal connection
            cli("sessions")
            connection = json.loads((home/"daemon.json").read_text())

        def api(path, data=None):
            request = urllib.request.Request(f"http://127.0.0.1:{connection['port']}" + path,
                headers={"Authorization": "Bearer " + connection["token"], "Content-Type": "application/json"},
                data=None if data is None else json.dumps(data).encode())
            with urllib.request.urlopen(request, timeout=25) as response:
                return json.load(response)

        def ready(session):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                if not api(f"/sessions/{session}/status")["running"]:
                    return
                time.sleep(.025)
            raise AssertionError("session did not settle")

        def stop():
            if not connection:
                return
            with contextlib.suppress(Exception):
                api("/shutdown", {})
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    os.kill(connection["pid"], 0)
                except ProcessLookupError:
                    return
                time.sleep(.05)
            raise AssertionError("daemon did not stop cleanly")

        def rejected(path, data):
            try:
                api(path, data)
                raise AssertionError("invalid extension change succeeded")
            except urllib.error.HTTPError as error:
                assert error.code == 409, error.read()

        def catalog_request(session, prompt):
            before = len(Provider.requests)
            api(f"/sessions/{session}/events", {"content": prompt})
            ready(session)
            assert len(Provider.requests) == before + 1
            return Provider.requests[-1]

        try:
            connect()
            daemon_pid = connection["pid"]
            assert "session_extensions" in api("/health")["capabilities"]
            session = json.loads(cli("new", str(workspace)))["session"]
            route = f"/sessions/{session}/extensions"
            installed = api(route)
            assert {"python", "bash", "work", "files", "skills"} <= {item["name"] for item in installed}
            assert all(item["enabled"] for item in installed if item["name"] in {"python", "bash", "work", "files", "skills"})
            request = catalog_request(session, "first turn")
            text = json.dumps(request["input"])
            assert "catalog-only fixture description" in text and str(skill.resolve()) in text, request
            assert "BODY_MUST_NOT_AUTOLOAD" not in json.dumps(request), request
            assert "catalog-only fixture description" not in request.get("instructions", ""), request
            assert text.index("catalog-only fixture description") < text.index("first turn")
            assert "returning {content, next_offset, size, truncated}" in text, request
            tools = {tool["name"] for tool in request["tools"]}
            installed = api(route)  # Managed capabilities resolve when the lazy worker opens.
            skills = next(item for item in installed if item["name"] == "skills")
            assert skills["requires"] == ["python"]
            assert "skills" in skills["python_modules"], skills
            assert skills["tools"] == []
            assert not {"skills_read", "skills_list"} & tools
            skill_catalog = api(f"/sessions/{session}/skills")
            assert skill_catalog["skills"] == [{
                "name": "demo",
                "description": "catalog-only fixture description",
                "command": "/demo",
                "source": str(skill.resolve()),
            }]
            before = len(Provider.requests)
            api(f"/sessions/{session}/skills/activate", {
                "name": "demo", "arguments": "one  two", "clientId": "fixture-client",
            })
            ready(session)
            assert len(Provider.requests) == before + 1
            activation = json.dumps(Provider.requests[-1]["input"])
            assert "BODY_MUST_NOT_AUTOLOAD" in activation
            assert "one  two" in activation and str(skill.resolve()) in activation
            commands = api(f"/sessions/{session}/skills")["skills"]
            assert commands == [{"name": "demo", "description": "catalog-only fixture description",
                                 "command": "/demo", "source": str(skill.resolve())}], commands
            original_skill = skill.read_text()
            skill.write_text(original_skill.replace("catalog-only fixture description", "changed on disk"))
            assert api(f"/sessions/{session}/skills")["skills"] == commands, "catalog changed without reload"
            skill.write_text(original_skill)
            before = len(Provider.requests)
            api(f"/sessions/{session}/skills/activate", {"name": "demo", "arguments": "slash argument"})
            ready(session)
            assert len(Provider.requests) == before + 1, "slash activation must submit exactly one turn"
            activation_request = Provider.requests[-1]
            activated = next(item["content"] for item in reversed(activation_request["input"]) if item.get("role") == "user")
            activation = json.loads(activated.split("\n", 1)[1])
            assert activation["name"] == "demo" and activation["arguments"] == "slash argument"
            assert activation["source"] == str(skill.resolve())
            assert "BODY_MUST_NOT_AUTOLOAD" in activation["instructions"]
            python_session = json.loads(cli("new", str(workspace)))["session"]
            before = len(Provider.requests)
            api(f"/sessions/{python_session}/events", {"content": "activate demo via python"})
            ready(python_session)
            assert len(Provider.requests) == before + 2, "python activation must not submit another user turn"
            tool_output = next(item["output"] for item in Provider.requests[-1]["input"] if item.get("type") == "function_call_output")
            assert "SKILL_PYTHON_ACTIVATION_OK" in tool_output, tool_output
            rejected(route, {"name": "not-installed", "enabled": False})
            rejected(route, {"name": "python", "enabled": False})
            assert api(route) == installed
            disabled = api(route, {"name": "skills", "enabled": False})
            assert not next(item["enabled"] for item in disabled if item["name"] == "skills")
            rejected(f"/sessions/{session}/skills/activate", {"name": "demo", "arguments": "must not run"})
            assert json.loads((home/"daemon.json").read_text())["pid"] == daemon_pid
            request = catalog_request(session, "extension disabled")
            assert "<available_skills>" not in json.dumps(request), request
            assert "skills" not in {module for item in disabled if item["enabled"] for module in item["python_modules"]}
            assert not {"skills_read", "skills_list"} & {tool["name"] for tool in request.get("tools", [])}
            api(f"/sessions/{session}/events", {"content": "hold this turn"})
            assert Provider.entered.wait(10)
            rejected(route, {"name": "skills", "enabled": True})
            assert api(route) == disabled
            Provider.release.set()
            ready(session)
            stop()
            connect()
            assert not next(item["enabled"] for item in api(route) if item["name"] == "skills")
            skill.write_text("---\nname: demo\ndescription: refreshed catalog description\n---\nBODY_MUST_NOT_AUTOLOAD\n")
            api(route, {"name": "skills", "enabled": True})
            request = catalog_request(session, "extension reloaded")
            assert "refreshed catalog description" in json.dumps(request)
            context = request["input"][0]["content"]
            assert "catalog-only fixture description" not in context
            assert "BODY_MUST_NOT_AUTOLOAD" not in context
            print("extension context, live toggles, busy/dependency guards, and persistence passed")
        finally:
            Provider.release.set()
            stop()


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        run(f"http://127.0.0.1:{server.server_port}/v1")
    finally:
        server.shutdown()
