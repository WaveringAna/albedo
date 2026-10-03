"""Durable transcript content, checkpoint forks, and retained execution traces."""

import json
import urllib.error
import urllib.parse

from harness import exclusive, operation_id

from integration_fixture import IntegrationScenario


class HistoryContentTests(IntegrationScenario):
    # exclusive: restarts the daemon
    @exclusive
    def test_tool_checkpoint_forks_without_executing_its_pending_call(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                unrelated = app.session()
                self.send(app, unrelated, "continue from branch")
                session = app.session()
                message = 'write and inspect a file: "\\\n' + "😀e\u0301漢" * 400
                self.send(app, session, message)
                entries = self.history(app, session)
                preview = self.read(app, f"/sessions/{session}?tail=0")["preview"]
                self.assertEqual(preview["text"], message[:256])
                self.assertLessEqual(len(preview["text"]), 256)
                self.assertLessEqual(len(preview["text"].encode("utf-8")), 1024)
                self.assertTrue(preview["truncated"])
                self.assertEqual(
                    preview["transcript_count"],
                    len(
                        {
                            entry["position"]
                            for entry in entries
                            if entry["kind"] != "continuation"
                        }
                    ),
                )
                summary = next(
                    item
                    for item in self.read(app, "/sessions?scope=all")["items"]
                    if item["id"] == session
                )
                self.assertEqual(summary["preview"], preview)
                self.assertEqual((app.workspace / "example.txt").read_text(), "hello\n")
                self.assertTrue(
                    any(
                        e["kind"] == "assistant" and self.entry_text(e) == "finished"
                        for e in entries
                    )
                )
                self.assertTrue(
                    any(
                        e["kind"] == "thinking"
                        and self.entry_text(e) == "reasoning about the task"
                        for e in entries
                    )
                )
                tool = next(e for e in entries if e["kind"] == "tool_result")
                result = next(
                    part["value"]
                    for part in tool["content"]
                    if part["kind"] == "json" and part["field"] == "result"
                )
                trace = next(
                    part["trace"] for part in tool["content"] if part["kind"] == "trace"
                )
                self.assertEqual(json.loads(result)["status"], "ok")
                self.assertTrue(
                    any(
                        a["kind"] == "read" and a["target"].endswith("example.txt")
                        for a in trace["activities"]
                    )
                )
                self.assertTrue(
                    any(c["path"].endswith("example.txt") for c in trace["changes"])
                )
                checkpoint = next(e for e in entries if e["kind"] == "tool_call")
                result_page = self.read(
                    app,
                    f"/sessions/{session}/history?after={checkpoint['position']}&limit=1",
                )
                self.assertFalse(
                    any(entry["kind"] == "tool_call" for entry in result_page["items"])
                )
                result_first = next(
                    entry
                    for entry in result_page["items"]
                    if entry["kind"] == "tool_result"
                )
                self.assertEqual(result_first["tool"]["name"], "python")
                self.assertEqual(
                    result_first["tool"]["tool_call_id"],
                    checkpoint["tool"]["tool_call_id"],
                )
                self.assertEqual(result_first["turn_id"], checkpoint["turn_id"])
                branch_id = operation_id()
                with app.api(
                    f"/sessions/{branch_id}",
                    {
                        "kind": "fork",
                        "source_session_id": session,
                        "checkpoint_id": checkpoint["checkpoint_id"],
                    },
                    method="PUT",
                    headers={"If-None-Match": "*"},
                ) as response:
                    branch = json.load(response)
                self.assertEqual(
                    (branch["provider_profile"], branch["model"]),
                    (app.profile, "fixture-model"),
                )
                branch_entries = self.history(app, branch_id)
                branch_preview = self.read(app, f"/sessions/{branch_id}?tail=0")[
                    "preview"
                ]
                self.assertEqual(
                    branch_preview["transcript_count"],
                    len(
                        {
                            entry["position"]
                            for entry in branch_entries
                            if entry["kind"] != "continuation"
                        }
                    ),
                )
                self.assertEqual(branch_preview["text"], message[:256])
                self.assertTrue(branch_preview["truncated"])
                pending_result = next(
                    e for e in branch_entries if e["kind"] == "tool_result"
                )
                self.assertIn(
                    "not executed after branch checkpoint",
                    json.dumps(pending_result["content"]),
                )
                self.assertEqual(
                    [
                        (e["kind"], e["content"], e["turn_id"])
                        for e in branch_entries
                        if e["id"] != pending_result["id"]
                    ],
                    [
                        (e["kind"], e["content"], e["turn_id"])
                        for e in entries
                        if e["position"] <= checkpoint["position"]
                    ],
                )
                start = len(self.provider.requests)
                self.send(app, branch_id, "continue from branch")
                continued = self.history(app, branch_id)
                continued_preview = self.read(app, f"/sessions/{branch_id}?tail=0")[
                    "preview"
                ]
                self.assertEqual(
                    continued_preview["transcript_count"],
                    len(
                        {
                            entry["position"]
                            for entry in continued
                            if entry["kind"] != "continuation"
                        }
                    ),
                )
                self.assertGreater(
                    len(
                        {
                            entry["position"]
                            for entry in continued
                            if entry["kind"] != "continuation"
                        }
                    ),
                    len(
                        {
                            entry["position"]
                            for entry in branch_entries
                            if entry["kind"] != "continuation"
                        }
                    ),
                )
                self.assertEqual(continued_preview["text"], "continue from branch")
                self.assertFalse(continued_preview["truncated"])
                requests = self.records(start)
                self.assertEqual(len(requests), 1)
                self.assertIn(
                    "/chat/completions"
                    if protocol == "chat_completions"
                    else "/responses",
                    requests[0]["path"],
                )
                inputs = requests[0]["request"][
                    "messages" if protocol == "chat_completions" else "input"
                ]
                outputs = [
                    i
                    for i in inputs
                    if i.get("role") == "tool"
                    or i.get("type") == "function_call_output"
                ]
                self.assertEqual(
                    [i.get("content", i.get("output")) for i in outputs],
                    ["not executed after branch checkpoint"],
                )
                self.assertEqual(self.history(app, session), entries)

    # exclusive: restarts the daemon
    @exclusive
    def test_unicode_history_pages_preserve_content_and_timestamps(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                self.send(app, session, "write and inspect a file")
                self.send(app, session, "review the result")
                timestamps = [
                    (e["kind"], e["content"], e["created_at"])
                    for e in self.history(app, session)
                    if e["kind"] in ("user", "assistant")
                ]
                self.assertTrue(timestamps)
                self.assertTrue(
                    all(isinstance(stamp, str) for _, _, stamp in timestamps)
                )
                self.restart(app)
                self.assertEqual(
                    [
                        (e["kind"], e["content"], e["created_at"])
                        for e in self.history(app, session)
                        if e["kind"] in ("user", "assistant")
                    ],
                    timestamps,
                )

                large_inputs = {}
                for index in range(3):
                    identity = operation_id()
                    body = f"continue from branch {index}: " + '😀e\u0301\\"\n' * 75_000
                    with app.api(
                        f"/sessions/{session}/inputs/{identity}",
                        {"kind": "message", "text": body},
                        method="PUT",
                    ) as response:
                        json.load(response)
                    app.idle(session, timeout=90)
                    large_inputs[identity] = body

                def traverse(path, direction):
                    collected, tokens = [], set()
                    for _ in range(100):
                        with app.api(path) as response:
                            encoded = response.read()
                        self.assertLessEqual(len(encoded), 1_048_576)
                        page = json.loads(encoded)
                        self.assertTrue(
                            page["items"], "history cursor failed to advance"
                        )
                        collected = (
                            page["items"] + collected
                            if direction == "older"
                            else collected + page["items"]
                        )
                        token = page[direction]
                        if token is None:
                            ids = [entry["id"] for entry in collected]
                            self.assertEqual(len(ids), len(set(ids)))
                            return collected
                        self.assertNotIn(token, tokens, "history cursor repeated")
                        tokens.add(token)
                        path = f"/sessions/{session}/history?limit=200&next={urllib.parse.quote(token, safe='')}"
                    self.fail("history pagination did not terminate")

                backwards = traverse(f"/sessions/{session}/history?limit=200", "older")
                forwards = traverse(
                    f"/sessions/{session}/history?after=0&limit=200", "newer"
                )
                self.assertEqual(
                    [entry["id"] for entry in forwards],
                    [entry["id"] for entry in backwards],
                )
                for entry in backwards:
                    if entry["input_id"] not in large_inputs:
                        continue
                    references = [
                        part["reference"]
                        for part in entry["content"]
                        if part["kind"] == "reference"
                    ]
                    self.assertEqual(len(references), 1)
                    reference = references[0]
                    pieces, offset, token = [], 0, None
                    for _ in range(100):
                        path = reference["url"]
                        if token is not None:
                            path += "?" + urllib.parse.urlencode({"next": token})
                        content = self.read(app, path)
                        for part in content["parts"]:
                            self.assertEqual(part["encoding"], "utf8")
                            self.assertEqual(part["offset_bytes"], offset)
                            pieces.append(part["text"])
                            offset += len(part["text"].encode("utf-8"))
                        token = content["next"]
                        if token is None:
                            self.assertTrue(content["parts"][-1]["complete"])
                            break
                    else:
                        self.fail("full content pagination did not terminate")
                    self.assertEqual(offset, reference["bytes"])
                    self.assertEqual(
                        "".join(pieces), large_inputs.pop(entry["input_id"])
                    )
                self.assertEqual(large_inputs, {})

    def test_fork_retains_continuation_and_trace_after_source_deletion(self):
        for protocol in ("responses", "chat_completions"):
            with self.subTest(protocol=protocol):
                app = self.app_for(protocol)
                session = app.session()
                self.send(app, session, "write and inspect a file")
                tool = next(
                    entry
                    for entry in self.history(app, session)
                    if entry["kind"] == "tool_result"
                )
                trace = next(
                    part["trace"] for part in tool["content"] if part["kind"] == "trace"
                )
                continuation_id = operation_id()
                with app.api(
                    f"/sessions/{session}/inputs/{continuation_id}",
                    {"kind": "continue"},
                    method="PUT",
                ) as response:
                    json.load(response)
                app.idle(session, timeout=90)
                continuation = next(
                    entry
                    for entry in self.history(app, session)
                    if entry["kind"] == "continuation"
                    and entry["input_id"] == continuation_id
                )
                self.send(app, session, "review the result")
                self.assertEqual(
                    self.read(app, f"/sessions/{session}")["automatic_name"],
                    "review the result",
                )
                backwards = self.history(app, session)
                trace_checkpoint = next(
                    entry
                    for entry in backwards
                    if entry["kind"] == "user"
                    and self.entry_text(entry) == "review the result"
                )
                retained_id = operation_id()
                with app.api(
                    f"/sessions/{retained_id}",
                    {
                        "kind": "fork",
                        "source_session_id": session,
                        "checkpoint_id": trace_checkpoint["checkpoint_id"],
                    },
                    method="PUT",
                    headers={"If-None-Match": "*"},
                ) as response:
                    json.load(response)

                def retained_trace():
                    history = self.history(app, retained_id)
                    marker = next(
                        entry
                        for entry in history
                        if entry["kind"] == "continuation"
                        and entry["input_id"] == continuation_id
                    )
                    self.assertEqual(marker["turn_id"], continuation["turn_id"])
                    self.assertEqual(marker["content"], continuation["content"])
                    result = next(
                        entry
                        for entry in history
                        if entry["kind"] == "tool_result"
                        and entry["tool"]["tool_call_id"]
                        == tool["tool"]["tool_call_id"]
                    )
                    return next(
                        part["trace"]
                        for part in result["content"]
                        if part["kind"] == "trace"
                    )

                self.assertEqual(retained_trace(), trace)
                resource = f"/sessions/{session}?view=configuration"
                with app.api(resource) as response:
                    json.load(response)
                    revision = response.headers["ETag"]
                with app.api(
                    resource, method="DELETE", headers={"If-Match": revision}
                ) as response:
                    self.assertEqual(json.load(response)["state"], "complete")
                self.assertEqual(retained_trace(), trace)
