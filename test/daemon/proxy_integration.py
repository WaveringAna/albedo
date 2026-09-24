"""The OpenAI-compatible proxy on a real daemon against fixture providers. No live model."""
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


class Provider(http.server.BaseHTTPRequestHandler):
    requests = []

    def log_message(self, *_):
        pass

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.requests.append((self.path, request))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        send = lambda value: self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
        if self.path.endswith("/chat/completions"):
            last = request["messages"][-1]
            if last["role"] == "tool":
                send({"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "content": "ran it"}, "finish_reason": None}]})
                send({"id": "c", "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]})
            else:
                send({"id": "c", "choices": [{"index": 0, "delta": {"role": "assistant", "reasoning_content": "hmm"}, "finish_reason": None}]})
                send({"id": "c", "choices": [{"index": 0, "delta": {"content": "hel"}, "finish_reason": None}]})
                send({"id": "c", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "id": "call-1", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":"}}]}, "finish_reason": None}]})
                send({"id": "c", "choices": [{"index": 0, "delta": {"tool_calls": [{"index": 0, "function": {"arguments": "\"ls\"}"}}]}, "finish_reason": None}]})
                send({"id": "c", "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}], "usage": {"prompt_tokens": 7, "completion_tokens": 3}})
            self.wfile.write(b"data: [DONE]\n\n")
        else:
            last = request["input"][-1]
            if last.get("role") == "user" and last.get("content") == "call a tool":
                output = [
                    {"type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "sealed-reasoning"},
                    {"type": "function_call", "id": "fc_1", "call_id": "call_r1", "name": "bash",
                     "arguments": "{\"command\":\"ls\"}", "status": "completed"},
                ]
            else:
                output = [{"type": "message", "role": "assistant", "status": "completed",
                           "content": [{"type": "output_text", "text": "done", "annotations": []}]}]
            send({"type": "response.completed", "response": {"id": "r", "status": "completed", "output": output,
                  "usage": {"input_tokens": 5, "output_tokens": 1}}})


def free_port():
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]


def post(url, body, headers=None):
    request = urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json", **(headers or {})})
    return urllib.request.urlopen(request, timeout=30)


def status(call):
    try:
        with call() as response:
            return response.status
    except urllib.error.HTTPError as error:
        return error.code


def chunks(response):
    events = [line[6:] for line in response.read().decode().splitlines() if line.startswith("data: ")]
    assert events[-1] == "[DONE]", events
    return [json.loads(event) for event in events[:-1]]


def main():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    endpoint = f"http://127.0.0.1:{server.server_address[1]}/v1"
    with tempfile.TemporaryDirectory(prefix="albedo-proxy-") as directory:
        home, user_home = Path(directory)/"state", Path(directory)/"user"
        home.mkdir(mode=0o700), user_home.mkdir(mode=0o700)
        (home/"config.json").write_text(json.dumps({"active": "chat", "providers": {
            "chat": {"baseUrl": endpoint, "apiKey": "k", "model": "m-chat", "protocol": "chat_completions"},
            "resp": {"baseUrl": endpoint, "apiKey": "k", "model": "m-resp", "protocol": "responses"},
        }}))
        settings = home/"extensions.json"
        settings.write_text(json.dumps({"models": {"refreshHours": 0}}))
        port = free_port()
        env = dict(os.environ, HOME=str(user_home), ALBEDO_HOME=str(home), ALBEDO_PORT=str(port),
                   ALBEDO_PARENT_PID=str(os.getpid()))
        result = subprocess.run(["node", "cli/bin/albedo.mjs", "sessions"], cwd=ROOT, env=env,
                                capture_output=True, text=True, timeout=60)
        assert result.returncode == 0, result.stdout + result.stderr
        assert json.loads((home/"daemon.json").read_text())["port"] == port
        base = f"http://127.0.0.1:{port}/proxy/v1"
        models = lambda: urllib.request.urlopen(base + "/models", timeout=10)

        # Disabled by default: the path falls through to the token-guarded daemon.
        assert status(models) == 403
        settings.write_text(json.dumps({"models": {"refreshHours": 0}, "enabled": {"proxy": True}}))
        with models() as response:
            ids = {model["id"] for model in json.load(response)["data"]}
        assert {"chat/m-chat", "resp/m-resp"} <= ids, ids
        assert status(lambda: post(base + "/chat/completions", {}, {"Origin": "https://example.com"})) == 403

        tools = [{"type": "function", "function": {"name": "bash", "parameters": {"type": "object"}}}]
        opening = [{"role": "system", "content": "be brief"}, {"role": "user", "content": "list files"}]
        with post(base + "/chat/completions", {"model": "chat", "messages": opening, "tools": tools,
                                               "stream": True, "stream_options": {"include_usage": True}}) as response:
            assert response.headers["content-type"].startswith("text/event-stream")
            stream = chunks(response)
        deltas = [c["choices"][0]["delta"] for c in stream if c["choices"]]
        assert deltas[0]["role"] == "assistant"
        assert "".join(d.get("content", "") for d in deltas) == "hel"
        assert "".join(d.get("reasoning_content", "") for d in deltas) == "hmm"
        calls = [call for d in deltas for call in d.get("tool_calls", [])]
        [streamed_call] = calls
        assert streamed_call["id"].startswith("call-1__albedo__"), streamed_call
        assert streamed_call["function"] == {"name": "bash", "arguments": "{\"command\":\"ls\"}"}, streamed_call
        assert [c["choices"][0]["finish_reason"] for c in stream if c["choices"]][-1] == "tool_calls"
        assert stream[-1]["usage"]["prompt_tokens"] == 7 and stream[-1]["choices"] == []
        assert all(c["model"] == "chat" for c in stream)
        path, sent = Provider.requests[-1]
        assert path == "/v1/chat/completions" and sent["model"] == "m-chat", (path, sent)
        assert sent["messages"][0] == {"role": "system", "content": "be brief"}, sent["messages"]

        history = opening + [
            {"role": "assistant", "content": "hel", "tool_calls": [{"id": "call-1", "type": "function",
             "function": {"name": "bash", "arguments": "{\"command\":\"ls\"}"}}]},
            {"role": "tool", "tool_call_id": "call-1", "content": "a.txt"},
        ]
        for model, check in (("chat/m-chat", "chat"), ("resp/m-resp", "responses")):
            with post(base + "/chat/completions", {"model": model, "messages": history, "tools": tools}) as response:
                completion = json.load(response)
            assert completion["object"] == "chat.completion", completion
            assert completion["choices"][0]["finish_reason"] == "stop", completion
            path, sent = Provider.requests[-1]
            if check == "chat":
                assert [m["role"] for m in sent["messages"]] == ["system", "user", "assistant", "tool"], sent
                assert sent["messages"][2]["tool_calls"][0]["id"] == "call-1"
            else:
                assert path == "/v1/responses" and sent["instructions"] == "be brief", sent
                kinds = [item.get("type", item.get("role")) for item in sent["input"]]
                assert kinds == ["user", "assistant", "function_call", "function_call_output"], sent["input"]
                assert sent["input"][3] == {"type": "function_call_output", "call_id": "call-1", "output": "a.txt"}

        # Provider state rides back through the client in the tool-call id.
        ask = [{"role": "user", "content": "call a tool"}]
        with post(base + "/chat/completions", {"model": "resp", "messages": ask, "tools": tools}) as response:
            first = json.load(response)["choices"][0]["message"]
        [call] = first["tool_calls"]
        assert call["id"].startswith("call_r1__albedo__"), call
        echoed = ask + [{"role": "assistant", "content": None, "tool_calls": [call]},
                        {"role": "tool", "tool_call_id": call["id"], "content": "a.txt"}]
        with post(base + "/chat/completions", {"model": "resp", "messages": echoed, "tools": tools}):
            pass
        path, sent = Provider.requests[-1]
        assert sent["input"][1] == {"type": "reasoning", "id": "rs_1", "summary": [],
                                    "encrypted_content": "sealed-reasoning"}, sent["input"]
        assert sent["input"][2]["call_id"] == "call_r1" and sent["input"][3]["call_id"] == "call_r1", sent["input"]
        # Another profile never sees that state; it gets the portable call.
        with post(base + "/chat/completions", {"model": "chat", "messages": echoed, "tools": tools}):
            pass
        path, sent = Provider.requests[-1]
        assert path == "/v1/chat/completions", path
        assert "sealed-reasoning" not in json.dumps(sent), sent
        assert sent["messages"][1]["tool_calls"][0]["id"] == "call_r1", sent["messages"]
        assert sent["messages"][2]["tool_call_id"] == "call_r1", sent["messages"]

        bad = lambda: post(base + "/chat/completions", {"model": "missing/x", "messages": opening})
        assert status(bad) == 400
    print("proxy: enablement, models, streaming chunks, projection, carried provider state, origin refusal passed")


if __name__ == "__main__":
    main()
