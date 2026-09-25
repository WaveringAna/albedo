"""Local end-to-end test: CLI startup, real HTTP streaming, Python, detach, replay, stop.
No live model credentials or network service required.
"""
import contextlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import sqlite3
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]

def content_text(item):
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(part["text"] for part in content if isinstance(part, dict) and isinstance(part.get("text"), str))
    return ""

class Provider(http.server.BaseHTTPRequestHandler):
    requests = []
    lock = threading.Lock()

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with self.lock:
            self.requests.append({
                "path": self.path,
                "authorization": self.headers.get("Authorization"),
                "model": request.get("model"),
                "request": request,
            })
        chat = self.path.endswith("chat/completions")
        inputs = request["messages" if chat else "input"]
        tool_turns = sum(item.get("role") == "tool" or item.get("type") == "function_call_output" for item in inputs)
        latest_user = next((content_text(item) for item in reversed(inputs) if item.get("role") == "user"), "")
        long_run = "over 100 turns" in latest_user
        done = tool_turns >= 105 if long_run else tool_turns > 0
        call_id = f"call-{tool_turns + 1}"
        slow = "hang" in latest_user
        code = "import asyncio, os\nfrom pathlib import Path\nPath('example.txt').write_text('hello\\n')\nsaved = Path('example.txt').read_text()\nassert 'ALBEDO_API_KEY' not in os.environ\nassert 'ALBEDO_TOKEN' not in os.environ\nawait asyncio.sleep(" + ("30" if slow else "0.4") + ")\nlen(saved)"
        if long_run:
            code = "1"
        if latest_user.startswith("workspace probe"):
            done = inputs[-1].get("role") == "tool" or inputs[-1].get("type") == "function_call_output"
            code = "import os\nfrom pathlib import Path\nassert 'workspace_marker' not in globals()\nworkspace_marker = os.getcwd()\nPath('cwd-probe').write_text(os.getcwd())"
        if latest_user == "continue from branch":
            done = tool_turns > 1
            code = "from pathlib import Path\nassert 'saved' not in globals()\nassert Path('example.txt').read_text() == 'hello\\n'\nbranch_only = True"
        arguments = json.dumps({"code": code, "timeout_ms": 60000})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        def event(value):
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()
        try:
            if chat:
                if not done:
                    event({"id":"r1","choices":[{"index":0,"delta":{"reasoning_content":"reasoning about the task"},"finish_reason":None}]})
                    for i in range(0, len(arguments), 20):
                        function = {"arguments": arguments[i:i+20]}
                        call = {"index": 0, "function": function}
                        if i == 0:
                            function["name"] = "python"
                            call.update(id=call_id, type="function")
                        event({"id":"r1", "choices":[{"index":0,"delta":{"tool_calls":[call]},"finish_reason":None}]})
                    event({"id":"r1", "choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]})
                else:
                    event({"id":"r2", "choices":[{"index":0,"delta":{"content":"finished"},"finish_reason":None}]})
                    event({"id":"r2", "choices":[{"index":0,"delta":{},"finish_reason":"stop"}]})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            else:
                event({"type":"response.created", "response":{"id":"r2" if done else "r1"}})
                if not done:
                    event({"type":"response.reasoning_summary_text.delta","output_index":0,"summary_index":0,"delta":"reasoning about the task"})
                    for i in range(0,len(arguments),20):
                        event({"type":"response.function_call_arguments.delta","output_index":0,"delta":arguments[i:i+20]})
                    output=[{"id":"rs1","type":"reasoning","summary":[{"type":"summary_text","text":"reasoning about the task"}]},{"id":"fc1","type":"function_call","call_id":call_id,"name":"python","arguments":arguments,"status":"completed"}]
                else:
                    event({"type":"response.output_text.delta","output_index":0,"content_index":0,"delta":"finished"})
                    output=[{"id":"m1","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"finished","annotations":[]}]}]
                event({"type":"response.completed","response":{"id":"r2" if done else "r1","status":"completed","output":output,"usage":{"input_tokens":10,"output_tokens":20}}})
        except (BrokenPipeError, ConnectionResetError):
            pass

def run(protocol, endpoint):
    with tempfile.TemporaryDirectory(prefix="albedo-daemon-test-") as directory:
        home = Path(directory)/"home"
        workspace = Path(directory)/"workspace"
        workspace.mkdir()
        switch_workspace = Path(directory)/"switch-workspace"
        switch_workspace.mkdir()
        busy_workspace = Path(directory)/"busy-workspace"
        busy_workspace.mkdir()
        busy_replacement = Path(directory)/"busy-replacement"
        busy_replacement.mkdir()
        # An old database has neither provider bindings nor the new column.
        home.mkdir(mode=0o700)
        legacy_id = "legacy-fixture"
        legacy_workspace = Path(directory)/"legacy-workspace"
        legacy_workspace.mkdir()
        with sqlite3.connect(home/"albedo.sqlite") as db:
            db.execute("CREATE TABLE sessions(id TEXT PRIMARY KEY,cwd TEXT NOT NULL,model TEXT NOT NULL,protocol TEXT NOT NULL,stage TEXT NOT NULL DEFAULT 'idle')")
            db.execute("INSERT INTO sessions(id,cwd,model,protocol) VALUES(?,?,?,?)", (legacy_id,str(legacy_workspace),"legacy-model",protocol))
        user_home = Path(directory)/"user-home"
        user_home.mkdir()
        # Catalog refresh is disabled so the suite never reaches the network.
        (home/"extensions.json").write_text(json.dumps({"models": {"refreshHours": 0}}))
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home), ALBEDO_PARENT_PID=str(os.getpid()))
        for obsolete in ("ALBEDO_API_KEY", "ALBEDO_BASE_URL", "ALBEDO_MODEL", "ALBEDO_PROTOCOL"):
            env.pop(obsolete, None)
        connection = None
        def command(*args):
            binary = os.environ.get("ALBEDO_TEST_BINARY")
            argv = [binary, *args] if binary else [str(ROOT / "cli/bin/albedo"), *args]
            return subprocess.run(argv, cwd=workspace if binary else ROOT, env=env, text=True, capture_output=True, timeout=45)
        def cli(*args):
            result = command(*args)
            assert result.returncode == 0, result.stdout + result.stderr + ((home/"daemon.log").read_text() if (home/"daemon.log").exists() else "")
            return result.stdout
        def configure(active, providers):
            home.mkdir(parents=True, exist_ok=True)
            (home/"config.json").write_text(json.dumps({"active": active, "providers": providers}))
        def provider(base, key, model, provider_protocol=protocol):
            return {"baseUrl": endpoint + base, "apiKey": key, "model": model, "protocol": provider_protocol}
        def api(path, body=None):
            headers={"Authorization":"Bearer " + connection["token"], "Content-Type":"application/json"}
            req=urllib.request.Request(base+path, headers=headers, data=None if body is None else json.dumps(body).encode())
            return urllib.request.urlopen(req, timeout=15)
        def ready(id, timeout=15):
            deadline = time.monotonic()+timeout
            while time.monotonic()<deadline:
                with api(f"/sessions/{id}/status") as response:
                    value=json.load(response)
                if not value["running"]:
                    return
                time.sleep(.05)
            raise AssertionError(f"worker did not settle: {value}\n{(home/'daemon.log').read_text()}")
        def snapshot(id):
            with api(f"/sessions/{id}/stream") as response:
                while True:
                    line=response.readline()
                    if line.startswith(b"data: "):
                        page=json.loads(line[6:])
                        return page["events"]
        def assert_projected_history(record, target_protocol, users):
            request=record["request"]
            items=request["messages" if target_protocol == "chat_completions" else "input"]
            saved=json.dumps(items)
            for user in users:
                assert user in saved, (user, items)
            assert "finished" in saved, items
            if target_protocol == "chat_completions":
                calls=[call["id"] for item in items if item.get("role") == "assistant" for call in item.get("tool_calls", [])]
                outputs=[item["tool_call_id"] for item in items if item.get("role") == "tool"]
            else:
                calls=[item["call_id"] for item in items if item.get("type") == "function_call"]
                outputs=[item["call_id"] for item in items if item.get("type") == "function_call_output"]
            assert "call-1" in calls, (calls, items)
            assert "call-1" in outputs, (outputs, items)
        try:
            # The daemon is useful before login: it starts and lists saved sessions.
            cli("sessions")
            connection=json.loads((home/"daemon.json").read_text())
            base=f"http://127.0.0.1:{connection['port']}"
            with api("/health") as response:
                health=json.load(response)
            assert health["ok"] is True and health["version"] == 2, health
            assert {"session_provider", "session_workspace"} <= set(health["capabilities"]), health
            try:
                api("/sessions", {"workspace": str(workspace)}).close()
                raise AssertionError("unconfigured session creation succeeded")
            except urllib.error.HTTPError as error:
                assert error.code == 400
                assert "/login" in json.load(error)["error"]

            configure("alpha", {
                "default": provider("/legacy/v1", "legacy-key", "legacy-model"),
                "alpha": provider("/alpha/v1", "alpha-1", "fixture-alpha"),
            })

            # The request boundary derives actual image metadata before durable
            # storage. A later turn proves both provider protocols retain the data
            # URL, while the user event exposes metadata only.
            vision_workspace = Path(directory)/"vision-workspace"
            vision_workspace.mkdir()
            vision=json.loads(cli("new",str(vision_workspace)))["session"]
            png="iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"
            attachment={"mimeType":"image/png","data":png,"width":2,"height":3,"bytes":24}
            try:
                api(f"/sessions/{vision}/events", {"content":"reject this", "image":dict(attachment,width=4)}).close()
                raise AssertionError("spoofed image metadata was accepted")
            except urllib.error.HTTPError as error:
                assert error.code == 409, error
            request_start=len(Provider.requests)
            with api(f"/sessions/{vision}/events", {"content":"describe this image", "image":attachment}):
                pass
            ready(vision)
            with api(f"/sessions/{vision}/events", {"content":"confirm image history"}):
                pass
            ready(vision)
            vision_requests=Provider.requests[request_start:]
            assert len(vision_requests) == 3, len(vision_requests)
            data_url="data:image/png;base64,"+png
            assert all(data_url in json.dumps(record["request"]) for record in vision_requests), vision_requests
            vision_events=snapshot(vision)
            image_event=next(event for event in vision_events if event.get("type")=="user" and event.get("image"))
            assert image_event["image"] == {"mimeType":"image/png","width":2,"height":3,"bytes":24}, image_event
            assert png not in json.dumps(image_event), image_event

            # Login may change the active provider before an old session is first reopened.
            request_start=len(Provider.requests)
            with api(f"/sessions/{legacy_id}/events", {"content":"inspect the legacy workspace"}):
                pass
            ready(legacy_id)
            legacy_requests=Provider.requests[request_start:]
            assert legacy_requests and all("/legacy/v1/" in item["path"] for item in legacy_requests), legacy_requests
            assert all(item["authorization"] == "Bearer legacy-key" for item in legacy_requests), legacy_requests
            first=json.loads(cli("new",str(workspace)))
            id=first["session"]
            with api("/sessions") as response:
                listed=json.load(response)
            first_info=next(item for item in listed if item["id"] == id)
            assert first_info["provider"] == "alpha"
            assert first_info["title"] == "new session"
            # Starting another client reuses the daemon, not a second runtime.
            cli("sessions")
            assert json.loads((home/"daemon.json").read_text())["pid"] == connection["pid"]

            # Config is re-read for each turn. The session stays on alpha even after beta becomes active.
            other_protocol = "chat_completions" if protocol == "responses" else "responses"
            configure("beta", {
                "alpha": provider("/alpha/v1", "alpha-2", "ignored-new-default"),
                "beta": provider("/beta/v1", "beta-1", "fixture-beta"),
                "gamma": provider("/gamma/v1", "gamma-1", "fixture-gamma", other_protocol),
            })

            # Busy chat messages steer at the next model boundary, after tool output.
            queue_workspace=Path(directory)/"queue-workspace"
            queue_workspace.mkdir()
            queued=json.loads(cli("new", str(queue_workspace)))["session"]
            request_start=len(Provider.requests)
            with api(f"/sessions/{queued}/events", {"content":"first task"}) as response:
                assert json.load(response)["queued"] is False
            time.sleep(.15)
            with api(f"/sessions/{queued}/events", {"content":"queued direction"}) as response:
                assert json.load(response)["queued"] is True
            with api(f"/sessions/{queued}/events", {"content":"another direction"}):
                pass
            ready(queued)
            queued_requests=Provider.requests[request_start:]
            assert len(queued_requests) == 2, queued_requests
            assert "queued direction" not in json.dumps(queued_requests[0]["request"]), queued_requests
            assert "queued direction" in json.dumps(queued_requests[1]["request"]), queued_requests
            assert "another direction" in json.dumps(queued_requests[1]["request"]), queued_requests
            assert json.dumps(queued_requests[1]["request"]).index("queued direction") < json.dumps(queued_requests[1]["request"]).index("another direction")
            assert any(e.get("type") == "user" and e.get("text") == "queued direction" for e in snapshot(queued)), snapshot(queued)

            # Workspace updates are idle-only and never interrupt active work.
            busy = json.loads(cli("new", str(busy_workspace)))["session"]
            with api(f"/sessions/{busy}/events", {"content":"hang while workspace update is attempted"}):
                pass
            time.sleep(.5)
            try:
                api(f"/sessions/{busy}/workspace", {"workspace":str(busy_replacement)}).close()
                raise AssertionError("busy workspace update succeeded")
            except urllib.error.HTTPError as error:
                assert error.code == 409
            with api(f"/sessions/{busy}/interrupt", {}):
                pass
            ready(busy)
            with api("/sessions") as response:
                busy_info = next(item for item in json.load(response) if item["id"] == busy)
            assert busy_info["workspace"] == str(busy_workspace), busy_info

            # Repair a renamed workspace without restarting daemon or losing history.
            original_workspace = Path(directory)/"original-workspace"
            original_workspace.mkdir()
            moved_workspace = Path(directory)/"moved-workspace"
            moved = json.loads(cli("new", str(original_workspace)))["session"]
            with api(f"/sessions/{moved}/events", {"content":"workspace probe before move"}):
                pass
            ready(moved)
            assert Path((original_workspace/"cwd-probe").read_text()).resolve() == original_workspace.resolve()
            original_workspace.rename(moved_workspace)
            before_repair = snapshot(moved)
            try:
                api(f"/sessions/{moved}/events", {"content":"workspace probe after move"}).close()
                raise AssertionError("missing workspace accepted a turn")
            except urllib.error.HTTPError as error:
                failure = json.load(error)
                assert error.code == 409 and failure["code"] == "workspace_missing", failure
                assert failure["workspace"] == str(original_workspace), failure
            for invalid in ["relative", str(original_workspace), str(moved_workspace/"cwd-probe")]:
                try:
                    api(f"/sessions/{moved}/workspace", {"workspace":invalid}).close()
                    raise AssertionError("invalid replacement workspace accepted")
                except urllib.error.HTTPError as error:
                    assert error.code == 409
            with api(f"/sessions/{moved}/workspace", {"workspace":str(moved_workspace)}) as response:
                repaired = json.load(response)
            assert repaired["workspace"] == str(moved_workspace), repaired
            with api("/sessions") as response:
                moved_info = next(item for item in json.load(response) if item["id"] == moved)
            assert moved_info["workspace"] == str(moved_workspace), moved_info
            assert json.loads((home/"daemon.json").read_text())["pid"] == connection["pid"]
            with api(f"/sessions/{moved}/events", {"content":"workspace probe after move"}):
                pass
            ready(moved)
            assert Path((moved_workspace/"cwd-probe").read_text()).resolve() == moved_workspace.resolve()
            assert not original_workspace.exists()
            after_repair = snapshot(moved)
            assert [event for event in before_repair if event.get("type") == "user"] == [event for event in after_repair if event.get("type") == "user"][:-1]
            with sqlite3.connect(home/"albedo.sqlite") as db:
                assert db.execute("SELECT cwd FROM sessions WHERE id=?", (moved,)).fetchone()[0] == str(moved_workspace)

            # Switch only after a complete assistant/tool conversation exists.
            switched=json.loads(cli("new",str(switch_workspace)))["session"]
            with api(f"/sessions/{switched}/commands", {"name":"/model", "args":{"provider":"alpha", "model":"initial-alpha"}}):
                pass
            request_start=len(Provider.requests)
            with api(f"/sessions/{switched}/events", {"content":"build switch history"}):
                pass
            ready(switched)
            initial_requests=Provider.requests[request_start:]
            assert len(initial_requests) >= 2, initial_requests
            assert all("/alpha/v1/" in item["path"] for item in initial_requests), initial_requests

            # The model endpoint atomically moves that history to another protocol.
            with api(f"/sessions/{switched}/commands", {"name":"/model", "args":{"provider":"gamma", "model":"chosen-gamma"}}) as response:
                selection=json.load(response)
            assert selection == {"result": {"provider":"gamma", "model":"chosen-gamma", "protocol":other_protocol, "effort":None}}, selection
            defaults=json.loads((home/"config.json").read_text())
            assert defaults["active"] == "gamma" and defaults["providers"]["gamma"]["model"] == "chosen-gamma", defaults
            with api("/sessions", {"workspace": str(workspace)}) as response:
                default_session=json.load(response)
            assert default_session["provider"] == "gamma" and default_session["model"] == "chosen-gamma", default_session
            # Existing model-only callers keep the current provider and protocol.
            with api(f"/sessions/{switched}/commands", {"name":"/model", "args":{"model":"renamed-gamma"}}) as response:
                selection=json.load(response)
            assert selection == {"result": {"provider":"gamma", "model":"renamed-gamma", "protocol":other_protocol, "effort":None}}, selection
            defaults=json.loads((home/"config.json").read_text())
            assert defaults["active"] == "gamma" and defaults["providers"]["gamma"]["model"] == "renamed-gamma", defaults
            try:
                api(f"/sessions/{switched}/commands", {"name":"/model", "args":{"provider":"unknown", "model":"wrong"}}).close()
                raise AssertionError("unknown provider switch succeeded")
            except urllib.error.HTTPError as error:
                assert error.code == 409
            request_start=len(Provider.requests)
            with api(f"/sessions/{switched}/events", {"content":"after first switch"}):
                pass
            ready(switched)
            gamma_requests=Provider.requests[request_start:]
            assert gamma_requests and all("/gamma/v1/" in item["path"] for item in gamma_requests), gamma_requests
            assert all(item["authorization"] == "Bearer gamma-1" for item in gamma_requests), gamma_requests
            assert all(item["model"] == "renamed-gamma" for item in gamma_requests), gamma_requests
            assert_projected_history(gamma_requests[0], other_protocol, ["build switch history", "after first switch"])

            # Switching back projects the newer foreign turn while preserving the
            # original provider's raw replay and every tool/result association.
            with api(f"/sessions/{switched}/commands", {"name":"/model", "args":{"provider":"alpha", "model":"returned-alpha"}}) as response:
                selection=json.load(response)
            assert selection == {"result": {"provider":"alpha", "model":"returned-alpha", "protocol":protocol, "effort":None}}, selection
            defaults=json.loads((home/"config.json").read_text())
            assert defaults["active"] == "alpha" and defaults["providers"]["alpha"]["model"] == "returned-alpha", defaults
            request_start=len(Provider.requests)
            with api(f"/sessions/{switched}/events", {"content":"after second switch"}):
                pass
            ready(switched)
            returned_requests=Provider.requests[request_start:]
            assert returned_requests and all("/alpha/v1/" in item["path"] for item in returned_requests), returned_requests
            assert all(item["model"] == "returned-alpha" for item in returned_requests), returned_requests
            assert_projected_history(returned_requests[0], protocol, ["build switch history", "after first switch", "after second switch"])
            with api("/sessions") as response:
                switched_info=next(item for item in json.load(response) if item["id"] == switched)
            assert (switched_info["provider"], switched_info["model"], switched_info["protocol"]) == ("alpha", "returned-alpha", protocol), switched_info

            request_start=len(Provider.requests)
            with api(f"/sessions/{id}/events",{"content":"write and inspect a file"}):
                pass
            snapshot(id)  # disconnect while the Python cell is still running
            ready(id)
            alpha_requests=Provider.requests[request_start:]
            assert alpha_requests and all("/alpha/v1/" in item["path"] for item in alpha_requests), alpha_requests
            assert all(item["authorization"] == "Bearer alpha-2" for item in alpha_requests), alpha_requests
            assert all(item["model"] == "fixture-alpha" for item in alpha_requests), alpha_requests
            events=snapshot(id)
            assert any(e.get("type")=="message" and e["text"]=="finished" for e in events), events
            assert any(e.get("type")=="thinking" and e["text"]=="reasoning about the task" for e in events), events
            tool=next(e for e in events if e.get("type")=="tool")
            outcome=json.loads(tool["result"])
            assert outcome.get("status")=="ok", outcome
            assert any(a["kind"]=="read" and a["target"].endswith("example.txt") for a in tool["trace"]["activities"]), tool
            assert any(c["path"].endswith("example.txt") for c in tool["trace"]["changes"]), tool

            # Tree checkpoints are durable transcript sequence numbers. Forking
            # at a call copies only that prefix and adds an explicit result
            # without executing the source call again.
            with api(f"/sessions/{id}/tree?after=0&limit=100") as response:
                source_tree = json.load(response)
            source_items = source_tree["items"]
            assert source_tree["hasMore"] is False
            assert {item["type"] for item in source_items} == {"user", "assistant", "tool"}, source_items
            # Only the Responses protocol stores reasoning as its own durable item.
            assert (protocol != "responses") or any(
                item["preview"].startswith("[reasoning]") for item in source_items), source_items
            call_checkpoint = next(item for item in source_items if item["preview"] == "call python")
            with api(f"/sessions/{id}/fork", {"checkpoint":call_checkpoint["id"]}) as response:
                branch_info = json.load(response)
            branch = branch_info["id"]
            assert branch_info["title"] == "write and inspect a file", branch_info
            assert (branch_info["provider"], branch_info["model"], branch_info["protocol"]) == ("alpha", "fixture-alpha", protocol), branch_info
            with api(f"/sessions/{branch}/tree?after=0&limit=100") as response:
                branch_tree = json.load(response)
            assert branch_tree["items"][-1]["preview"] == "not executed after branch checkpoint", branch_tree
            assert [item["preview"] for item in branch_tree["items"][:-1]] == [item["preview"] for item in source_items if item["id"] <= call_checkpoint["id"]]
            request_start = len(Provider.requests)
            with api(f"/sessions/{branch}/events", {"content":"continue from branch"}):
                pass
            ready(branch)
            branch_requests = Provider.requests[request_start:]
            # The synthetic result completes the copied call, so the branch turn
            # needs one request and never re-runs the source tool.
            assert len(branch_requests) == 1, branch_requests
            assert all("/alpha/v1/" in item["path"] and item["model"] == "fixture-alpha" for item in branch_requests), branch_requests
            branch_inputs = branch_requests[0]["request"]["messages" if protocol == "chat_completions" else "input"]
            outputs = [item for item in branch_inputs if item.get("role") == "tool" or item.get("type") == "function_call_output"]
            assert [item.get("content", item.get("output")) for item in outputs] == ["not executed after branch checkpoint"], outputs
            assert any(event.get("type") == "message" and event.get("text") == "finished" for event in snapshot(branch))
            with api(f"/sessions/{id}/tree?after=0&limit=100") as response:
                assert json.load(response)["items"] == source_items, "fork mutated source transcript"

            with api("/sessions") as response:
                listed=json.load(response)
            assert next(item for item in listed if item["id"] == id)["title"] == "write and inspect a file"
            with api(f"/sessions/{id}/events",{"content":"review the result"}):
                pass
            ready(id)
            with api("/sessions") as response:
                listed=json.load(response)
            assert next(item for item in listed if item["id"] == id)["title"] == "review the result"
            message_times = [(e["type"], e["text"], e.get("timestamp")) for e in snapshot(id) if e.get("type") in ("user", "message")]
            assert message_times and all(isinstance(stamp, int) for _, _, stamp in message_times)
            configure("beta", {
                "alpha": provider("/alpha/v1", "alpha-2", "returned-alpha"),
                "beta": provider("/beta/v1", "beta-1", "fixture-beta"),
                "gamma": provider("/gamma/v1", "gamma-1", "renamed-gamma", other_protocol),
            })
            # A single uninterrupted run can cross the former 100-model-turn ceiling.
            long_session=json.loads(cli("new",str(workspace)))["session"]
            request_start=len(Provider.requests)
            with api(f"/sessions/{long_session}/events", {"content":"continue for over 100 turns"}):
                pass
            ready(long_session, timeout=60)
            assert len(Provider.requests[request_start:]) == 106
            long_events=snapshot(long_session)
            assert sum(e.get("type") == "tool" for e in long_events) == 105
            assert any(e.get("type") == "message" and e["text"] == "finished" for e in long_events)
            # A separate session can be interrupted without stopping the daemon.
            second=json.loads(cli("new",str(workspace)))["session"]
            with api("/sessions") as response:
                listed=json.load(response)
            second_info=next(item for item in listed if item["id"] == second)
            assert second_info["provider"] == "beta" and second_info["model"] == "fixture-beta", second_info
            request_start=len(Provider.requests)
            with api(f"/sessions/{second}/events",{"content":"hang"}):
                pass
            time.sleep(.5)
            for operation, body in [("workspace", {"workspace":str(moved_workspace)}), ("commands", {"name":"/model", "args":{"provider":"gamma", "model":"busy-rejected"}})]:
                try:
                    api(f"/sessions/{second}/{operation}", body).close()
                    raise AssertionError("busy session changed " + operation)
                except urllib.error.HTTPError as error:
                    assert error.code == 409
            with api("/sessions") as response:
                unchanged = next(item for item in json.load(response) if item["id"] == second)
            assert unchanged["workspace"] == str(workspace) and unchanged["provider"] == "beta"
            with api(f"/sessions/{second}/interrupt",{}):
                pass
            ready(second)
            beta_requests=Provider.requests[request_start:]
            assert beta_requests and all("/beta/v1/" in item["path"] for item in beta_requests), beta_requests
            assert all(item["authorization"] == "Bearer beta-1" for item in beta_requests), beta_requests
            assert any(e.get("type")=="user" for e in snapshot(second))
            third=json.loads(cli("new",str(workspace)))["session"]
            with api(f"/sessions/{third}/events",{"content":"hang then recover"}):
                pass
            time.sleep(.5)
            stamp=(workspace/"example.txt").stat().st_mtime_ns
            configure("alpha", {
                "alpha": provider("/alpha/v1", "alpha-3", "changed-alpha-default"),
                "beta": provider("/beta/v1", "beta-2", "changed-beta-default"),
                "gamma": provider("/gamma/v1", "gamma-2", "changed-gamma-default", other_protocol),
            })
            request_start=len(Provider.requests)
            os.kill(connection["pid"],9)
            # Reopening the CLI starts the daemon and resumes work on its saved provider.
            cli("sessions")
            connection=json.loads((home/"daemon.json").read_text())
            base=f"http://127.0.0.1:{connection['port']}"
            ready(third)
            restored=snapshot(third)
            assert any(e.get("type")=="message" and e["text"]=="finished" for e in restored), restored
            resumed_requests=Provider.requests[request_start:]
            assert resumed_requests and all("/beta/v1/" in item["path"] for item in resumed_requests), resumed_requests
            assert all(item["authorization"] == "Bearer beta-2" for item in resumed_requests), resumed_requests
            assert all(item["model"] == "fixture-beta" for item in resumed_requests), resumed_requests
            # The resumed turn is told about the restart, and the kernel reset rides along.
            resumed_input=resumed_requests[0]["request"]["messages" if protocol == "chat_completions" else "input"]
            restart_note=[content_text(item) for item in resumed_input if item.get("role") == "user"][-1]
            assert restart_note.startswith('<system-note origin="daemon restart">albedo restarted'), restart_note
            assert "<system-note>The python kernel" in restart_note, restart_note
            markers=[e for e in restored if e.get("type") == "user" and e.get("source") == "daemon restart"]
            assert len(markers) == 1 and markers[0]["text"].startswith("albedo restarted"), restored
            with api("/sessions") as response:
                restored_sessions={item["id"]: item for item in json.load(response)}
            assert restored_sessions[moved]["workspace"] == str(moved_workspace)
            assert restored_sessions[legacy_id]["provider"] == "default"
            assert restored_sessions[legacy_id]["title"] == "inspect the legacy workspace"
            assert restored_sessions[id]["provider"] == "alpha"
            assert restored_sessions[id]["title"] == "review the result"
            assert restored_sessions[third]["provider"] == "beta"
            assert restored_sessions[third]["title"] == "hang then recover"
            assert (restored_sessions[switched]["provider"], restored_sessions[switched]["model"], restored_sessions[switched]["protocol"]) == ("alpha", "returned-alpha", protocol)
            request_start=len(Provider.requests)
            with api(f"/sessions/{switched}/events", {"content":"after persisted restart"}):
                pass
            ready(switched)
            restarted_requests=Provider.requests[request_start:]
            assert restarted_requests and all("/alpha/v1/" in item["path"] for item in restarted_requests), restarted_requests
            assert all(item["model"] == "returned-alpha" for item in restarted_requests), restarted_requests
            assert_projected_history(restarted_requests[0], protocol, ["build switch history", "after first switch", "after second switch", "after persisted restart"])
            assert (workspace/"example.txt").stat().st_mtime_ns == stamp, "interrupted Python cell was replayed"
            recovered = snapshot(id)
            assert any(e.get("type")=="message" for e in recovered), "completed history lost"
            assert [(e["type"], e["text"], e.get("timestamp")) for e in recovered if e.get("type") in ("user", "message")] == message_times
            print(protocol+": provider switching, config reload, detach, tools, trace, interrupt, and recovery passed")
        finally:
            if connection:
                with contextlib.suppress(Exception):
                    api("/shutdown",{}).close()
                deadline=time.monotonic()+10
                while time.monotonic()<deadline:
                    try:
                        os.kill(connection["pid"],0)
                    except ProcessLookupError:
                        break
                    time.sleep(.05)
                else:
                    os.kill(connection["pid"],9)

if __name__ == "__main__":
    server=http.server.ThreadingHTTPServer(("127.0.0.1",0),Provider)
    thread=threading.Thread(target=server.serve_forever,daemon=True)
    thread.start()
    try:
        for protocol in ("responses","chat_completions"):
            run(protocol,f"http://127.0.0.1:{server.server_port}/v1")
    finally:
        server.shutdown()
