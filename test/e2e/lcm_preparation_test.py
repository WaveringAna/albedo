"""Forced LCM preparation preserves its newest tool unit and stored summaries."""

import json
import unittest

from harness import Albedo, Provider, python, text


class LcmPreparationTests(unittest.TestCase):
    def test_forced_fold_retains_tool_tail_on_next_preparation(self):
        def reply(request):
            inputs = request["input"]
            if "<newly-evicted-history>" in json.dumps(inputs):
                return text("archived earlier conversation")
            if inputs[-1].get("type") == "function_call_output":
                return text("tool finished")
            if inputs[-1].get("content") == "newest tool unit":
                return python("print('TAIL_TOOL_OUTPUT')")
            return text("ordinary answer")

        provider = Provider(reply)
        self.addCleanup(provider.close)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            for prompt in ("older unit one", "older unit two", "newest tool unit"):
                app.prompt(session, prompt).close()
                app.idle(session)
            with app.api(
                f"/sessions/{session}/compaction",
                {"strategy": "lcm"},
            ) as response:
                result = json.load(response)
            self.assertEqual(result["state"], "compacted")
            app.idle(session)
            app.prompt(session, "after fold").close()
            app.idle(session)
            sent = provider.requests[-1]["request"]["input"]
            self.assertIn("LCM summary node #", json.dumps(sent))
            self.assertIn("newest tool unit", json.dumps(sent))
            self.assertIn("TAIL_TOOL_OUTPUT", json.dumps(sent))
            calls = [
                item["call_id"] for item in sent if item.get("type") == "function_call"
            ]
            outputs = [
                item["call_id"]
                for item in sent
                if item.get("type") == "function_call_output"
            ]
            self.assertEqual(calls, outputs)
            with app.api(f"/sessions/{session}/context") as response:
                observation = json.load(response)["compaction"]
            self.assertEqual(observation["strategy"], "lcm")
