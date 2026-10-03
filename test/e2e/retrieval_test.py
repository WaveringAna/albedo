"""Retrieval keeps exact counts, scoped pages, and Unicode text offsets through the daemon."""

import json
import unittest

from harness import Albedo, Provider, Reply, python, text


class RetrievalTests(unittest.TestCase):
    def setUp(self):
        self.code = None
        self.tool = None
        self.arguments = None

        def script(request):
            last = request["input"][-1]
            if last.get("type") == "function_call_output":
                return text("done")
            if "<newly-evicted-history>" in str(last.get("content", "")):
                return text("fold-only Café")
            if self.code is not None:
                return python(self.code)
            if self.tool is not None:
                return Reply(
                    "python", tool_name=self.tool, tool_arguments=self.arguments
                )
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def turn(self, session, prompt):
        before = len(self.provider.requests)
        self.app.prompt(session, prompt).close()
        self.app.idle(session)
        return [entry["request"] for entry in self.provider.requests[before:]]

    def retrieve(self, name, arguments):
        self.tool, self.arguments = name, arguments
        requests = self.turn(self.session, "retrieve fixture")
        output = next(
            item["output"]
            for item in reversed(requests[-1]["input"])
            if item.get("type") == "function_call_output"
        )
        return json.loads(output)

    def test_transcript_pages_count_matches_and_preserve_grapheme_offsets(self):
        target = self.app.session()
        for prompt in ["é👩‍💻tail Café\r", "second Café", "third Café"]:
            self.turn(target, prompt)
        self.code = f"""
agent = await agents.get({target!r})
found = await agent.search_messages('CAFÉ', limit=1)
assert found.count == 3, found
assert len(found.rows) == 1 and found.next_offset == 1, found
seq = found.rows[0]['seq']
second = await agent.search_messages('CAFÉ', offset=1, limit=1)
assert second.count == 3 and second.rows[0]['seq'] > seq, second
end = await agent.search_messages('CAFÉ', offset=3, limit=1)
assert end.count == 3 and end.rows == [] and end.next_offset is None, end
prefix = len(f'[row #{{seq}}]\\n[user]\\n')
accent = await agent.messages(seq=seq, offset=prefix, limit=1)
assert accent.content == 'é', accent
emoji = await agent.messages(seq=seq, offset=prefix+1, limit=1)
assert emoji.content == '👩‍💻', emoji
boundary = await agent.messages(seq=seq, offset=prefix+11, limit=1)
assert boundary.content == '\\r\\n', boundary
separator = await agent.messages(seq=seq, offset=prefix+12, limit=1)
assert separator.content == '\\n', separator
beyond = await agent.messages(seq=seq, offset=100000, limit=1)
assert beyond.content == '' and beyond.next_offset is None, beyond
try:
    await agent.messages(seq=seq, offset=-1)
    assert False, 'negative offset was accepted'
except AgentsError as error:
    assert 'nonnegative' in str(error), error
print('RETRIEVAL_PAGES_OK')
"""
        requests = self.turn(self.session, "verify source retrieval")
        output = next(
            item["output"]
            for item in reversed(requests[-1]["input"])
            if item.get("type") == "function_call_output"
        )
        self.assertIn("RETRIEVAL_PAGES_OK", output)

    def test_lcm_search_pages_sources_and_nodes_independently_inside_selected_range(
        self,
    ):
        for prompt in ["first Café", "second Café", "third Café", "fourth Café"]:
            self.turn(self.session, prompt)
        with self.app.api(
            f"/sessions/{self.session}/compaction",
            {"strategy": "lcm"},
        ) as response:
            result = json.load(response)
        self.assertEqual(result["state"], "compacted")
        self.app.idle(self.session)
        listed = self.retrieve("lcm_list", {"limit": 1})
        self.assertGreater(listed["total"], 0)
        self.assertEqual(len(listed["folds"]), 1)
        node = listed["folds"][0]
        self.assertTrue(node["frontier"])
        scoped = self.retrieve(
            "lcm_grep", {"pattern": "CAFÉ", "summary_id": node["id"], "limit": 1}
        )
        self.assertGreater(scoped["source_count"], 1)
        self.assertEqual(scoped["node_count"], 1)
        self.assertEqual(len(scoped["sources"]), 1)
        self.assertEqual(len(scoped["nodes"]), 1)
        self.assertEqual(scoped["next_offset"], 1)
        source = scoped["sources"][0]
        self.assertEqual(source["node_id"], node["id"])
        self.assertGreaterEqual(source["seq"], node["first_seq"])
        self.assertLessEqual(source["seq"], node["last_seq"])
        second = self.retrieve(
            "lcm_grep",
            {"pattern": "CAFÉ", "summary_id": node["id"], "limit": 1, "offset": 1},
        )
        self.assertEqual(second["source_count"], scoped["source_count"])
        self.assertEqual(second["node_count"], 1)
        self.assertEqual(len(second["sources"]), 1)
        self.assertEqual(second["nodes"], [])
        self.assertEqual(second["next_offset"], 2)
        summary_only = self.retrieve(
            "lcm_grep", {"pattern": "fold-only", "summary_id": node["id"], "limit": 1}
        )
        self.assertEqual(summary_only["source_count"], 0)
        self.assertEqual(summary_only["node_count"], 1)
        self.assertEqual(summary_only["sources"], [])
        self.assertEqual(len(summary_only["nodes"]), 1)
        self.assertIsNone(summary_only["next_offset"])
        page = self.retrieve("lcm_expand", {"id": node["id"], "limit": 1})
        self.assertEqual(page["content"], "[")
        self.assertEqual(page["next_offset"], 1)
        continued = self.retrieve(
            "lcm_expand", {"id": node["id"], "limit": 1, "offset": 1}
        )
        self.assertEqual(continued["content"], "s")
        outside = self.retrieve(
            "lcm_grep", {"pattern": "CAFÉ", "summary_id": node["id"], "offset": 1000}
        )
        self.assertEqual(outside["source_count"], scoped["source_count"])
        self.assertEqual(outside["sources"], [])
        self.assertIsNone(outside["next_offset"])
