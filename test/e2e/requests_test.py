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

from harness import Albedo, Provider, Reply, text

FIRST = {"input_tokens": 100, "output_tokens": 20,
         "input_tokens_details": {"cached_tokens": 40},
         "output_tokens_details": {"reasoning_tokens": 7}}
TOOL = {"input_tokens": 200, "output_tokens": 30,
        "input_tokens_details": {"cached_tokens": 80},
        "output_tokens_details": {"reasoning_tokens": 11}}
AFTER = {"input_tokens": 300, "output_tokens": 40,
         "input_tokens_details": {"cached_tokens": 120},
         "output_tokens_details": {"reasoning_tokens": 3}}
THIRD = {"input_tokens": 400, "output_tokens": 50,
         "input_tokens_details": {"cached_tokens": 160},
         "output_tokens_details": {"reasoning_tokens": 5}}
SUMMARY = {"input_tokens": 60, "output_tokens": 10}
POST = {"input_tokens": 70, "output_tokens": 15,
        "input_tokens_details": {"cached_tokens": 30},
        "output_tokens_details": {"reasoning_tokens": 2}}


def reply(request):
    inputs = request["input"]
    # The tool result arrives while the newest user message is still the one
    # that asked for the tool, so it is told apart by input shape.
    if inputs[-1].get("type") == "function_call_output":
        return text("tool done", usage=AFTER)
    user = next((str(item.get("content", "")) for item in reversed(inputs)
                 if item.get("role") == "user"), "")
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
        with app.api(f"/sessions/{session}/requests{query}") as response:
            return json.load(response)

    def tree(self, app, session):
        """Every transcript row through the tree route, oldest first."""
        items, after = [], 0
        while True:
            with app.api(f"/sessions/{session}/tree?after={after}&limit=100") \
                    as response:
                page = json.load(response)
            items.extend(page["items"])
            if not page["hasMore"]:
                return items
            after = page["nextCursor"]

    def test_rows_record_usage_identity_prefix_and_projection(self):
        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                session = app.session()
                for prompt in ("first", "use the tool", "third", "hit the limit"):
                    app.prompt(session, prompt).close()
                    app.idle(session)
                with app.api(f"/sessions/{session}/commands",
                             {"name": "/compact"}) as response:
                    self.assertTrue(json.load(response)["result"]["started"])
                app.idle(session)
                app.prompt(session, "after compaction").close()
                app.idle(session)

                page = self.rows(app, session)
                rows = page["rows"]
                self.assertEqual([row["kind"] for row in rows],
                                 ["turn", "turn", "turn", "turn", "turn",
                                  "summarizer", "turn"])
                # Every call carries its own reported counts, split as sent.
                self.assertEqual([(row["inputTokens"], row["outputTokens"],
                                   row["cachedInputTokens"],
                                   row["reasoningTokens"]) for row in rows],
                                 [(100, 20, 40, 7), (200, 30, 80, 11),
                                  (300, 40, 120, 3), (400, 50, 160, 5),
                                  (None, None, None, None),
                                  (60, 10, None, None), (70, 15, 30, 2)])
                # The head (instructions and tools) never changed, so one hash.
                heads = {row["headHash"] for row in rows if row["kind"] == "turn"}
                self.assertEqual(len(heads), 1)
                self.assertNotIn(rows[5]["headHash"], heads)

                for row in rows:
                    self.assertIsNone(row["account"])
                    # The shared harness names the fixture profile per route.
                    self.assertTrue(row["profile"].startswith("fixture"))
                    self.assertEqual(row["model"], "fixture-model")
                    self.assertTrue(row["provider"].startswith("responses:"))
                    self.assertLessEqual(row["startedMs"], row["finishedMs"])
                    # An OpenAI-protocol provider caches on its own; albedo marks nothing.
                    self.assertEqual(row["cacheMarks"], [])

                for row in rows[:4] + [rows[6]]:
                    self.assertEqual(row["outcome"], "ok")
                    self.assertIsNone(row["status"])
                    self.assertIsNone(row["error"])

                for row in rows[:4]:
                    # Nothing replaced yet: the identity is a plain append.
                    self.assertEqual(row["replaced"], 0)
                    self.assertIsNone(row["projectionHash"])

                # A 429 is a quota reading, with no usage and no transcript row.
                limited = rows[4]
                self.assertEqual(limited["outcome"], "error")
                self.assertEqual(limited["status"], 429)
                self.assertIn("limit exceeded", limited["error"])
                self.assertIsNone(limited["seq"])

                # Each turn row's seq is the transcript row its response
                # committed, exactly: the assistant row that turn produced,
                # found again through the tree route straight from the
                # transcript.
                tree = self.tree(app, session)
                assistant = {item["preview"]: item["id"] for item in tree
                             if item["type"] == "assistant"}
                self.assertEqual(rows[0]["seq"], assistant["first reply"])
                self.assertEqual(rows[2]["seq"], assistant["tool done"])
                self.assertEqual(rows[3]["seq"], assistant["third reply"])
                self.assertEqual(rows[6]["seq"],
                                 assistant["post compaction reply"])
                # The tool-call turn's row points at its own assistant row,
                # the call it produced, not the tool output after it.
                calls = [item for item in tree
                         if item["preview"] == "call python"]
                self.assertEqual(len(calls), 1)
                self.assertEqual(rows[1]["seq"], calls[0]["id"])
                tool_output = tree[tree.index(calls[0]) + 1]
                self.assertEqual(tool_output["type"], "tool")
                self.assertNotEqual(tool_output["id"], rows[1]["seq"])
                # Linked rows sit in transcript order.
                linked = [row["seq"] for row in rows if row["seq"] is not None]
                self.assertEqual(linked, sorted(linked))

                # The compaction summary call is its own kind, outside the
                # session projection.
                summary = rows[5]
                self.assertIsNone(summary["seq"])
                self.assertIsNone(summary["replaced"])
                self.assertIsNone(summary["projectionHash"])
                self.assertEqual(summary["inputs"], 1)

                # The projection identity changes once compaction rewrites the
                # head the verbatim tail hangs from.
                after = rows[6]
                self.assertGreater(after["replaced"], 0)
                self.assertIsNotNone(after["projectionHash"])
                self.assertTrue(after["strategy"])

                # Paging: continue after the first row, bounded by limit.
                second = self.rows(app, session,
                                   f"?after={rows[0]['id']}&limit=2")
                self.assertEqual([row["id"] for row in second["rows"]],
                                 [row["id"] for row in rows[1:3]])
                self.assertEqual(second["after"], rows[2]["id"])
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
                rows = self.rows(app, session)["rows"]
                self.assertEqual([row["outcome"] for row in rows],
                                 ["error"] * 4 + ["ok"])
                self.assertEqual({row["status"] for row in rows[:4]}, {503})
                self.assertIsNotNone(rows[4]["seq"])
                # Each wait doubles from 250ms, measured from the failed
                # attempt's end to the next one's start.
                gaps = [after["startedMs"] - before["finishedMs"]
                        for before, after in zip(rows, rows[1:])]
                for gap, wait in zip(gaps, (250, 500, 1000, 2000)):
                    self.assertGreaterEqual(gap, wait)
        finally:
            provider.close()


if __name__ == "__main__":
    unittest.main()
