"""OpenAI-compatible proxy enablement, model routing, streaming, and state projection."""
import json
import unittest
import urllib.error
import urllib.request

from harness import Albedo, Provider, exclusive, Reply

TOOLS = [{"type": "function", "function": {"name": "bash", "parameters": {"type": "object"}}}]
OPENING = [{"role": "system", "content": "be brief"}, {"role": "user", "content": "list files"}]
CALL = {"id": "call-1", "type": "function", "function": {"name": "bash", "arguments": '{"command":"ls"}'}}
HISTORY = OPENING + [{"role": "assistant", "content": "hel", "tool_calls": [CALL]},
                     {"role": "tool", "tool_call_id": "call-1", "content": "a.txt"}]


def fixture(request):
    if "messages" in request:
        if request["messages"][-1]["role"] == "tool":
            deltas = [({"role": "assistant", "content": "ran it"}, None), ({}, "stop")]
        else:
            deltas = [({"role": "assistant", "reasoning_content": "hmm"}, None),
                      ({"content": "hel"}, None),
                      ({"tool_calls": [{"index": 0, **CALL, "function": {"name": "bash", "arguments": '{"command":'}}]}, None),
                      ({"tool_calls": [{"index": 0, "function": {"arguments": '"ls"}'}}]}, None),
                      ({}, "tool_calls")]
        events = [{"id": "c", "choices": [{"index": 0, "delta": delta, "finish_reason": reason}],
                   **({"usage": {"prompt_tokens": 7, "completion_tokens": 3}} if reason == "tool_calls" else {})}
                  for delta, reason in deltas]
    else:
        last = request["input"][-1]
        if last.get("role") == "user" and last.get("content") == "call a tool":
            output = [{"type": "reasoning", "id": "rs_1", "summary": [], "encrypted_content": "sealed-reasoning"},
                      {"type": "function_call", "id": "fc_1", "call_id": "call_r1", "name": "bash",
                       "arguments": '{"command":"ls"}', "status": "completed"}]
        else:
            output = [{"type": "message", "role": "assistant", "status": "completed",
                       "content": [{"type": "output_text", "text": "done", "annotations": []}]}]
        events = [{"type": "response.completed", "response": {"id": "r", "status": "completed", "output": output,
                   "usage": {"input_tokens": 5, "output_tokens": 1}}}]
    return Reply("raw", events=events)


class ProxyTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(fixture)
        self.addCleanup(self.provider.close)
        endpoint = self.provider.url + "/v1"
        self.chat = f"chat-{self.provider.route}"
        self.resp = f"resp-{self.provider.route}"
        self.cx = f"cx-{self.provider.route}"
        self.broken = f"broken-{self.provider.route}"
        profiles = {
            self.chat: {"baseUrl": endpoint, "apiKey": "k", "model": "m-chat", "protocol": "chat_completions"},
            self.resp: {"baseUrl": endpoint, "apiKey": "k", "model": "m-resp", "protocol": "responses"},
            self.cx: {"extension": "codex", "model": "gpt-saved", "protocol": "responses"},
            self.broken: {"model": 3},
        }

        self.app = Albedo(self.provider, providers=profiles)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.base = self.app.base + "/proxy/v1"

    def get_models(self):
        return urllib.request.urlopen(self.base + "/models", timeout=10)

    def enable(self):
        (self.app.home / "extensions.json").write_text(json.dumps({
            "models": {"refreshHours": 0}, "enabled": {"proxy": True}}))

    def post(self, body, *, headers=None):
        request = urllib.request.Request(self.base + "/chat/completions", json.dumps(body).encode(),
                                         {"Content-Type": "application/json", **(headers or {})})
        return urllib.request.urlopen(request, timeout=30)

    def sent(self):
        record = self.provider.requests[-1]
        return record["path"], record["request"]

    @exclusive
    def test_enablement_listing_and_profile_errors(self):
        (self.app.home / "extensions.json").write_text(json.dumps({
            "models": {"refreshHours": 0}, "enabled": {"proxy": False}}))
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.get_models()
        self.assertEqual(rejected.exception.code, 403)
        self.enable()
        with self.get_models() as response:
            listing = json.load(response)
        self.assertTrue({f"{self.chat}/m-chat", f"{self.resp}/m-resp", f"{self.cx}/gpt-saved"}
                        <= {model["id"] for model in listing["data"]})
        self.assertIn(self.broken, [error["profile"] for error in listing["errors"]])
        with self.post({"model": f"{self.chat}/unlisted", "messages": [{"role": "user", "content": "hi"}]}) as response:
            self.assertEqual(json.load(response)["model"], f"{self.chat}/unlisted")
        self.assertEqual(self.sent()[1]["model"], "unlisted")
        for model in (self.broken, f"{self.cx}/gpt-saved"):
            with self.subTest(model=model), self.assertRaises(urllib.error.HTTPError) as rejected:
                self.post({"model": model, "messages": [{"role": "user", "content": "hi"}]})
            self.assertEqual(rejected.exception.code, 400)
            self.assertIn("/login", json.load(rejected.exception)["error"]["message"])
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.post({}, headers={"Origin": "https://example.com"})
        self.assertEqual(rejected.exception.code, 403)
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            self.post({"model": "missing/x", "messages": OPENING})
        self.assertEqual(rejected.exception.code, 400)

    def test_streamed_chat_deltas_usage_and_provider_routing(self):
        with self.post({"model": self.chat, "messages": OPENING, "tools": TOOLS,
                        "stream": True, "stream_options": {"include_usage": True}}) as response:
            self.assertTrue(response.headers["content-type"].startswith("text/event-stream"))
            lines = [line[6:] for line in response.read().decode().splitlines() if line.startswith("data: ")]
        self.assertEqual(lines[-1], "[DONE]")
        stream = [json.loads(line) for line in lines[:-1]]
        deltas = [event["choices"][0]["delta"] for event in stream if event["choices"]]
        self.assertEqual(deltas[0]["role"], "assistant")
        self.assertEqual("".join(delta.get("content", "") for delta in deltas), "hel")
        self.assertEqual("".join(delta.get("reasoning_content", "") for delta in deltas), "hmm")
        [call] = [call for delta in deltas for call in delta.get("tool_calls", [])]
        self.assertTrue(call["id"].startswith("call-1__albedo__"))
        self.assertEqual(call["function"], CALL["function"])
        self.assertEqual([event["choices"][0]["finish_reason"] for event in stream if event["choices"]][-1], "tool_calls")
        self.assertEqual(stream[-1]["usage"]["prompt_tokens"], 7)
        self.assertEqual(stream[-1]["choices"], [])
        self.assertTrue(all(event["model"] == self.chat for event in stream))
        path, sent = self.sent()
        self.assertTrue(path.endswith("/v1/chat/completions"), path)
        self.assertEqual(sent["model"], "m-chat")
        self.assertEqual(sent["messages"][0], OPENING[0])

    def test_chat_and_responses_history_projection(self):
        for model in (f"{self.chat}/m-chat", f"{self.resp}/m-resp"):
            with self.subTest(model=model):
                with self.post({"model": model, "messages": HISTORY, "tools": TOOLS}) as response:
                    completion = json.load(response)
                self.assertEqual(completion["object"], "chat.completion")
                self.assertEqual(completion["choices"][0]["finish_reason"], "stop")
                path, sent = self.sent()
                if model.startswith(self.chat):
                    self.assertEqual([message["role"] for message in sent["messages"]],
                                     ["system", "user", "assistant", "tool"])
                    self.assertEqual(sent["messages"][2]["tool_calls"][0]["id"], "call-1")
                else:
                    self.assertTrue(path.endswith("/v1/responses"), path)
                    self.assertEqual(sent["instructions"], "be brief")
                    self.assertEqual([item.get("type", item.get("role")) for item in sent["input"]],
                                     ["user", "assistant", "function_call", "function_call_output"])
                    self.assertEqual(sent["input"][3],
                                     {"type": "function_call_output", "call_id": "call-1", "output": "a.txt"})

    def test_response_state_round_trips_only_to_originating_profile(self):
        ask = [{"role": "user", "content": "call a tool"}]
        with self.post({"model": self.resp, "messages": ask, "tools": TOOLS}) as response:
            first = json.load(response)["choices"][0]["message"]
        [call] = first["tool_calls"]
        self.assertTrue(call["id"].startswith("call_r1__albedo__"))
        echoed = ask + [{"role": "assistant", "content": None, "tool_calls": [call]},
                        {"role": "tool", "tool_call_id": call["id"], "content": "a.txt"}]
        with self.post({"model": self.resp, "messages": echoed, "tools": TOOLS}):
            pass
        sent = self.sent()[1]
        self.assertEqual(sent["input"][1], {"type": "reasoning", "id": "rs_1", "summary": [],
                                              "encrypted_content": "sealed-reasoning"})
        self.assertEqual([sent["input"][index]["call_id"] for index in (2, 3)], ["call_r1"] * 2)
        with self.post({"model": self.chat, "messages": echoed, "tools": TOOLS}):
            pass
        path, sent = self.sent()
        self.assertTrue(path.endswith("/v1/chat/completions"), path)
        self.assertNotIn("sealed-reasoning", json.dumps(sent))
        self.assertEqual(sent["messages"][1]["tool_calls"][0]["id"], "call_r1")
        self.assertEqual(sent["messages"][2]["tool_call_id"], "call_r1")


if __name__ == "__main__":
    unittest.main()
