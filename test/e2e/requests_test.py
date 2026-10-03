"""Provider requests: one durable row per attempt albedo sends, recording what cache
and quota analysis cannot recover from the transcript.

Catches: usage counts that never reach a request row (cache reads, TTL-split
writes, reasoning), the account/provider identity of each call, the prefix
identity that distinguishes a warm append from a compaction rewrite, an HTTP
failure recorded as a quota reading, and the seq link to the transcript. None
of this is observable from events or history alone.
"""

import json
import unittest
from datetime import datetime

from harness import Albedo, Provider, Reply, text

FIRST = {
    "input_tokens": 100,
    "output_tokens": 20,
    "input_tokens_details": {"cached_tokens": 40},
    "output_tokens_details": {"reasoning_tokens": 7},
}
TOOL = {
    "input_tokens": 200,
    "output_tokens": 30,
    "input_tokens_details": {"cached_tokens": 80},
    "output_tokens_details": {"reasoning_tokens": 11},
}
AFTER = {
    "input_tokens": 300,
    "output_tokens": 40,
    "input_tokens_details": {"cached_tokens": 120},
    "output_tokens_details": {"reasoning_tokens": 3},
}
THIRD = {
    "input_tokens": 400,
    "output_tokens": 50,
    "input_tokens_details": {"cached_tokens": 160},
    "output_tokens_details": {"reasoning_tokens": 5},
}
SUMMARY = {"input_tokens": 60, "output_tokens": 10}
POST = {
    "input_tokens": 70,
    "output_tokens": 15,
    "input_tokens_details": {"cached_tokens": 30},
    "output_tokens_details": {"reasoning_tokens": 2},
}


def reply(request):
    inputs = request["input"]
    # The tool result arrives while the newest user message is still the one
    # that asked for the tool, so it is told apart by input shape.
    if inputs[-1].get("type") == "function_call_output":
        return text("tool done", usage=AFTER)
    user = next(
        (
            str(item.get("content", ""))
            for item in reversed(inputs)
            if item.get("role") == "user"
        ),
        "",
    )
    if "<newly-evicted-history>" in user:
        return text("older conversation summary", usage=SUMMARY)
    if user == "use the tool":
        return Reply("python", "2 + 2", usage=TOOL)
    if user == "hit the limit":
        return Reply("error", "limit exceeded", status=429)
    if user == "after compaction":
        return text("post compaction reply", usage=POST)
    if user == "third":
        return text("third reply", usage=THIRD)
    return text("first reply", usage=FIRST)


class ProviderRequestsTest(unittest.TestCase):
    def rows(self, app, session, query=""):
        with app.api(f"/sessions/{session}/context?view=requests{query}") as response:
            return json.load(response)

    def history(self, app, session):
        items, after = [], 0
        while True:
            with app.api(
                f"/sessions/{session}/history?after={after}&limit=100"
            ) as response:
                page = json.load(response)
            items.extend(page["items"])
            if page["newer"] is None:
                return items
            after = items[-1]["position"]

    def test_rows_record_usage_identity_prefix_and_projection(self):
        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                session = app.session()
                for prompt in ("first", "use the tool", "third", "hit the limit"):
                    app.prompt(session, prompt).close()
                    app.idle(session)
                with app.api(f"/sessions/{session}/compaction", {}) as response:
                    self.assertEqual(json.load(response)["state"], "compacted")
                app.idle(session)
                app.prompt(session, "after compaction").close()
                app.idle(session)

                page = self.rows(app, session)
                rows = page["items"]
                self.assertEqual(
                    [row["kind"] for row in rows],
                    [
                        "turn",
                        "turn",
                        "turn",
                        "turn",
                        "turn",
                        "summarizer",
                        "summarizer",
                        "turn",
                    ],
                )
                # Every call carries its own reported counts, split as sent.
                self.assertEqual(
                    [
                        (
                            row["prompt_tokens"]["observed"],
                            row["completion_tokens"]["observed"],
                            row["cached_tokens"]["observed"],
                            row["reasoning_tokens"]["observed"],
                        )
                        for row in rows
                    ],
                    [
                        (100, 20, 40, 7),
                        (200, 30, 80, 11),
                        (300, 40, 120, 3),
                        (400, 50, 160, 5),
                        (None, None, None, None),
                        (60, 10, None, None),
                        (60, 10, None, None),
                        (70, 15, 30, 2),
                    ],
                )
                # The head (instructions and tools) never changed, so one hash.
                heads = {row["head_hash"] for row in rows if row["kind"] == "turn"}
                self.assertEqual(len(heads), 1)
                self.assertNotIn(rows[5]["head_hash"], heads)

                for row in rows:
                    self.assertIsNone(row["account_id"])
                    # The shared harness names the fixture profile per route.
                    self.assertTrue(row["provider_profile"].startswith("fixture"))
                    self.assertEqual(row["model"], "fixture-model")
                    self.assertTrue(row["provider"].startswith("responses:"))
                    self.assertLessEqual(row["started_at"], row["ended_at"])
                    # An OpenAI-protocol provider caches on its own; albedo marks nothing.
                    self.assertEqual(row["cache_marks"], [])

                for row in rows[:4] + [rows[7]]:
                    self.assertEqual(row["outcome"], "completed")
                    self.assertIsNone(row["http_status"])
                    self.assertIsNone(row["failure"])

                for row in rows[:4]:
                    # Nothing replaced yet: the identity is a plain append.
                    self.assertEqual(row["replaced_input_count"], 0)
                    self.assertIsNone(row["projection_hash"])

                # A 429 is a quota reading, with no usage and no transcript row.
                limited = rows[4]
                self.assertEqual(limited["outcome"], "failed")
                self.assertEqual(limited["http_status"], 429)
                self.assertEqual(set(limited["failure"]), {"code", "detail"})
                self.assertEqual(limited["failure"]["code"], "provider_request_failed")
                self.assertIn("limit exceeded", limited["failure"]["detail"])
                self.assertLessEqual(len(limited["failure"]["detail"]), 4096)
                self.assertEqual(limited["transcript_positions"], [])

                # Each turn row's seq is the transcript row its response
                # committed, exactly: the assistant row that turn produced,
                # found again through the tree route straight from the
                # transcript.
                entries = self.history(app, session)
                assistant = {
                    part["text"]: entry["position"]
                    for entry in entries
                    if entry["kind"] == "assistant"
                    for part in entry["content"]
                    if part["kind"] == "text"
                }
                for index, message in (
                    (0, "first reply"),
                    (2, "tool done"),
                    (3, "third reply"),
                    (7, "post compaction reply"),
                ):
                    self.assertIn(
                        assistant[message], rows[index]["transcript_positions"]
                    )
                calls = [entry for entry in entries if entry["kind"] == "tool_call"]
                self.assertEqual(len(calls), 1)
                self.assertIn(calls[0]["position"], rows[1]["transcript_positions"])
                tool_output = entries[entries.index(calls[0]) + 1]
                self.assertEqual(tool_output["kind"], "tool_result")
                self.assertNotIn(
                    tool_output["position"], rows[1]["transcript_positions"]
                )
                linked = [
                    position for row in rows for position in row["transcript_positions"]
                ]
                self.assertEqual(linked, sorted(linked))

                # The summary and the notes rewrite are their own kind,
                # outside the session projection.
                for summary in rows[5:7]:
                    self.assertEqual(summary["transcript_positions"], [])
                    self.assertIsNone(summary["replaced_input_count"])
                    self.assertIsNone(summary["projection_hash"])
                    self.assertEqual(summary["input_count"], 1)

                # The projection identity changes once compaction rewrites the
                # head the verbatim tail hangs from.
                after = rows[7]
                self.assertGreater(after["replaced_input_count"], 0)
                self.assertIsNotNone(after["projection_hash"])
                self.assertTrue(after["strategy"])

                # Paging: continue after the first row, bounded by limit.
                second = self.rows(
                    app, session, f"&after={rows[0]['sequence']}&limit=2"
                )
                self.assertEqual(
                    [row["sequence"] for row in second["items"]],
                    [row["sequence"] for row in rows[1:3]],
                )
                self.assertIsNotNone(second["next"])
        finally:
            provider.close()

    def test_a_failing_gateway_is_retried_with_doubling_waits(self):
        failures = []

        def script(request):
            if len(failures) < 4:
                failures.append(1)
                return Reply("error", "gateway down", status=503)
            return text("recovered")

        provider = Provider(script)
        try:
            with Albedo(provider, protocol="responses") as app:
                session = app.session()
                app.prompt(session, "hello").close()
                app.idle(session, timeout=60)
                rows = self.rows(app, session)["items"]
                self.assertEqual(
                    [row["outcome"] for row in rows], ["failed"] * 4 + ["completed"]
                )
                self.assertEqual({row["http_status"] for row in rows[:4]}, {503})
                self.assertTrue(rows[4]["transcript_positions"])
                # Each wait doubles from 250ms, measured from the failed
                # attempt's end to the next one's start.
                gaps = [
                    (
                        datetime.fromisoformat(
                            after["started_at"].replace("Z", "+00:00")
                        )
                        - datetime.fromisoformat(
                            before["ended_at"].replace("Z", "+00:00")
                        )
                    ).total_seconds()
                    * 1000
                    for before, after in zip(rows, rows[1:])
                ]
                for gap, wait in zip(gaps, (250, 500, 1000, 2000)):
                    self.assertGreaterEqual(gap, wait)
        finally:
            provider.close()
