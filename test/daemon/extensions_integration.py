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
        if prompt == "model probe via python" and messages[-1].get("type") != "function_call_output":
            code = ("selection = await commands.model()\n"
                    "assert selection['model'] == 'fixture', selection\n"
                    "try:\n"
                    "    await commands.model('unreachable-model')\n"
                    "    assert False, 'switch must refuse from the model'\n"
                    "except CommandsError as error:\n"
                    "    assert 'user action' in str(error), error\n"
                    "print('MODEL_COMMAND_OK')")
            output = [{"type": "function_call", "id": "fc-model", "call_id": "call-model",
                       "name": "python", "arguments": json.dumps({"code": code, "timeout_ms": 10000}),
                       "status": "completed"}]
        if prompt == "activate demo via python" and messages[-1].get("type") != "function_call_output":
            code = "activation = await commands.demo('python argument')\nassert 'BODY_MUST_NOT_AUTOLOAD' in activation['instructions']\nassert activation['arguments'] == 'python argument'\nprint('SKILL_PYTHON_ACTIVATION_OK')"
            output = [{"type": "function_call", "id": "fc-skills", "call_id": "call-skills",
                       "name": "python", "arguments": json.dumps({"code": code, "timeout_ms": 10000}),
                       "status": "completed"}]
        if prompt == "hot probe before reload" and messages[-1].get("type") != "function_call_output":
            code = ("names = [c['name'] for c in await commands.catalog()]\n"
                    "assert '/late' not in names, names\n"
                    "hot_marker = 'kernel-kept-running'\n"
                    "print('BEFORE_RELOAD_OK')")
            output = [{"type": "function_call", "id": "fc-hot-before", "call_id": "call-hot-before",
                       "name": "python", "arguments": json.dumps({"code": code, "timeout_ms": 10000}),
                       "status": "completed"}]
        if prompt == "hot probe after reload" and messages[-1].get("type") != "function_call_output":
            code = ("names = [c['name'] for c in await commands.catalog()]\n"
                    "assert '/late' in names, names\n"
                    "assert hot_marker == 'kernel-kept-running', 'kernel was restarted'\n"
                    "print('AFTER_RELOAD_OK')")
            output = [{"type": "function_call", "id": "fc-hot-after", "call_id": "call-hot-after",
                       "name": "python", "arguments": json.dumps({"code": code, "timeout_ms": 10000}),
                       "status": "completed"}]
        if prompt == "lcm tool probe" and messages[-1].get("type") != "function_call_output":
            output = [{"type": "function_call", "id": "fc-lcm-grep", "call_id": "call-lcm-grep",
                       "name": "lcm_grep", "arguments": json.dumps({"pattern": "first turn"}),
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
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home), ALBEDO_PARENT_PID=str(os.getpid()))
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

        def snapshot(session):
            # `api` would json.load an endless event stream; read one frame instead.
            # after_seq=0 replays the live log: a fresh stream gets a transcript
            # snapshot, which does not carry live-only events like `compacted`.
            request = urllib.request.Request(f"http://127.0.0.1:{connection['port']}/sessions/{session}/stream?after_seq=0",
                headers={"Authorization": "Bearer " + connection["token"]})
            with urllib.request.urlopen(request, timeout=25) as response:
                while True:
                    line = response.readline()
                    if line.startswith(b"data: "):
                        return json.loads(line[6:])["events"]

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
            assert skills["requires"] == ["python", "commands"]
            assert "skills" in skills["python_modules"], skills
            assert skills["tools"] == []
            assert not {"skills_read", "skills_list"} & tools
            catalog = api(f"/sessions/{session}/commands")
            demo = [c for c in catalog if c["name"] == "/demo"]
            assert demo == [{
                "name": "/demo",
                "description": "catalog-only fixture description",
                "method": "demo",
                "usage": "/demo [arguments]",
                "arguments": [{"name": "arguments", "description": "arguments for the skill", "required": False}],
                "modelCallable": True,
                "userTurn": True,
                "page": False,
            }], demo
            assert {c["name"] for c in catalog} >= {"/model", "/context", "/compact"}
            before = len(Provider.requests)
            outcome = api(f"/sessions/{session}/commands", {
                "name": "/demo", "arguments": "one  two", "clientId": "fixture-client",
            })
            assert outcome == {"submitted": True}, outcome
            ready(session)
            assert len(Provider.requests) == before + 1
            activation = json.dumps(Provider.requests[-1]["input"])
            assert "BODY_MUST_NOT_AUTOLOAD" in activation
            assert "one  two" in activation and str(skill.resolve()) in activation
            before = len(Provider.requests)
            original_tree = api(f"/sessions/{session}/tree?after=0&limit=100")["items"]
            started = api(f"/sessions/{session}/commands", {"name": "/compact"})
            assert started["result"]["strategy"] == "rolling" and started["result"]["started"] is True, started
            ready(session)
            assert len(Provider.requests) == before + 1, "only the active summarizer may call the provider"
            assert api(f"/sessions/{session}/tree?after=0&limit=100")["items"] == original_tree, "manual compaction rewrote the transcript"
            before = len(Provider.requests)
            api(f"/sessions/{session}/events", {"content": "after manual compaction"})
            ready(session)
            assert len(Provider.requests) == before + 1
            followup = json.dumps(Provider.requests[-1]["input"])
            assert "older conversation summary" in followup, "compacted projection was not reused: LOG: " + (home/"daemon.log").read_text()[-3000:] + " CONTEXT: " + json.dumps(api(f"/sessions/{session}/context"))[:1200]
            assert api(f"/sessions/{session}/context")["compaction"]["status"] == "compacted"
            context = api(f"/sessions/{session}/context")
            assert context["state"] == "ready" and context["compaction"]["status"] == "compacted", context
            events = snapshot(session)
            compacted = next(e for e in events if e.get("type") == "compacted")
            assert compacted["evicted"] > 0 and "older conversation summary" in compacted["summary"], compacted
            prepared = api(f"/sessions/{session}/context/history/0")["content"]
            assert "older conversation summary" in prepared, prepared
            listed = api(f"/sessions/{session}/commands")
            assert listed == catalog, listed
            original_skill = skill.read_text()
            skill.write_text(original_skill.replace("catalog-only fixture description", "changed on disk"))
            assert api(f"/sessions/{session}/commands") == catalog, "catalog changed without reload"
            skill.write_text(original_skill)
            before = len(Provider.requests)
            api(f"/sessions/{session}/commands", {"name": "/demo", "arguments": "slash argument"})
            ready(session)
            assert len(Provider.requests) == before + 1, "slash activation must submit exactly one turn"
            activated = next(item["content"] for item in reversed(Provider.requests[-1]["input"]) if item.get("role") == "user")
            activation = json.loads(activated.split("\n", 1)[1])
            assert activation["name"] == "demo" and activation["arguments"] == "slash argument"
            assert activation["source"] == str(skill.resolve())
            assert "BODY_MUST_NOT_AUTOLOAD" in activation["instructions"]
            # A skill written after the session opened stays invisible until a
            # session reload — then reaches the menu, the prompt context, and the
            # live kernel's routes in one swap, with the kernel still running.
            late = workspace/".agents"/"skills"/"late"/"SKILL.md"
            late.parent.mkdir(parents=True)
            late.write_text("---\nname: late\ndescription: added after the session opened\n---\nLATE_BODY\n")
            assert "/late" not in {c["name"] for c in api(f"/sessions/{session}/commands")}
            before = len(Provider.requests)
            api(f"/sessions/{session}/events", {"content": "hot probe before reload"})
            ready(session)
            assert len(Provider.requests) == before + 2
            tool_output = next(item["output"] for item in reversed(Provider.requests[-1]["input"]) if item.get("type") == "function_call_output")
            assert "BEFORE_RELOAD_OK" in tool_output, tool_output
            reloaded = api(f"/sessions/{session}/commands", {"name": "/reload", "args": {"target": "session"}})
            assert reloaded["result"]["reloaded"] == "session", reloaded
            assert "/late" in {c["name"] for c in api(f"/sessions/{session}/commands")}
            request = catalog_request(session, "after session reload")
            assert "added after the session opened" in json.dumps(request["input"]), request
            before = len(Provider.requests)
            api(f"/sessions/{session}/events", {"content": "hot probe after reload"})
            ready(session)
            assert len(Provider.requests) == before + 2
            tool_output = next(item["output"] for item in reversed(Provider.requests[-1]["input"]) if item.get("type") == "function_call_output")
            assert "AFTER_RELOAD_OK" in tool_output, tool_output
            python_session = json.loads(cli("new", str(workspace)))["session"]
            before = len(Provider.requests)
            api(f"/sessions/{python_session}/events", {"content": "activate demo via python"})
            ready(python_session)
            assert len(Provider.requests) == before + 2, "python activation must not submit another user turn"
            tool_output = next(item["output"] for item in reversed(Provider.requests[-1]["input"]) if item.get("type") == "function_call_output")
            assert "SKILL_PYTHON_ACTIVATION_OK" in tool_output, tool_output
            model_session = json.loads(cli("new", str(workspace)))["session"]
            before = len(Provider.requests)
            api(f"/sessions/{model_session}/events", {"content": "model probe via python"})
            ready(model_session)
            assert len(Provider.requests) == before + 2
            tool_output = next(item["output"] for item in reversed(Provider.requests[-1]["input"]) if item.get("type") == "function_call_output")
            assert "MODEL_COMMAND_OK" in tool_output, tool_output
            switched = api(f"/sessions/{model_session}/commands", {"name": "/model", "args": {"model": "switched-model"}})
            assert switched["result"]["model"] == "switched-model", switched
            assert switched["result"]["provider"] == "fixture", switched
            listed_sessions = api("/sessions")
            assert next(s for s in listed_sessions if s["id"] == model_session)["model"] == "switched-model"
            # /work is the work extension's own page. A user change is told to
            # the agent, but never starts a turn: while idle it waits and rides
            # ahead of the next message.
            work_command = next(c for c in api(f"/sessions/{session}/commands") if c["name"] == "/work")
            assert work_command["page"] is True and not work_command["modelCallable"], work_command
            page = api(f"/sessions/{session}/commands", {"name": "/work", "args": {}})["result"]["page"]
            assert page["title"] == "work" and {action["key"] for action in page["actions"]} >= {"a", "d", "x"}, page
            added = api(f"/sessions/{session}/commands", {"name": "/work", "args": {"action": "add", "details": "write the release notes"}})
            assert "the agent will be told" in added["result"]["message"], added
            before = len(Provider.requests)
            time.sleep(0.3)
            assert len(Provider.requests) == before, "a ledger note must not start a turn"
            request = catalog_request(session, "anything new on the ledger?")
            text = json.dumps(request["input"])
            assert "The user added work item" in text, text
            assert text.index("The user added work item") < text.index("anything new on the ledger?"), text
            page = api(f"/sessions/{session}/commands", {"name": "/work", "args": {}})["result"]["page"]
            assert any(row["text"] == "write the release notes" for row in page["glance"]["rows"]), page
            rejected(route, {"name": "not-installed", "enabled": False})
            rejected(route, {"name": "python", "enabled": False})
            assert api(route) == installed
            disabled = api(route, {"name": "skills", "enabled": False})
            assert not next(item["enabled"] for item in disabled if item["name"] == "skills")
            rejected(f"/sessions/{session}/commands", {"name": "/demo", "arguments": "must not run"})
            assert json.loads((home/"daemon.json").read_text())["pid"] == daemon_pid
            request = catalog_request(session, "extension disabled")
            assert "<available_skills>" not in json.dumps(request), request
            assert "skills" not in {module for item in disabled if item["enabled"] for module in item["python_modules"]}
            assert not {"skills_read", "skills_list"} & {tool["name"] for tool in request.get("tools", [])}
            api(f"/sessions/{session}/events", {"content": "hold this turn"})
            assert Provider.entered.wait(10)
            rejected(route, {"name": "skills", "enabled": True})
            rejected(f"/sessions/{session}/commands", {"name": "/model", "args": {"model": "mid-run"}})
            rejected(f"/sessions/{session}/commands", {"name": "/compact"})
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
            rejected(route, {"name": "lcm", "enabled": True})
            api(route, {"name": "rolling", "enabled": False})
            lcm_selected = api(route, {"name": "lcm", "enabled": True})
            assert next(item["enabled"] for item in lcm_selected if item["name"] == "lcm")
            lcm_request = catalog_request(session, "lcm preflight")
            assert {"lcm_grep", "lcm_describe", "lcm_expand"} <= {tool["name"] for tool in lcm_request["tools"]}
            compacted = api(f"/sessions/{session}/commands", {"name": "/compact"})
            assert compacted["result"]["strategy"] == "lcm" and compacted["result"]["started"] is True
            ready(session)
            before = len(Provider.requests)
            api(f"/sessions/{session}/events", {"content": "lcm tool probe"})
            ready(session)
            assert len(Provider.requests) == before + 2
            lcm_request = Provider.requests[before]
            assert "LCM summary node #" in json.dumps(lcm_request["input"]), lcm_request
            tool_result = next(item["output"] for item in reversed(Provider.requests[-1]["input"])
                               if item.get("type") == "function_call_output")
            assert "source_count" in tool_result and "first turn" in tool_result, tool_result
            assert api(f"/sessions/{session}/context")["compaction"]["strategy"] == "lcm"
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
