"""Transcript paging and what the transcript keeps, through the real daemon."""
import json
import unittest

from harness import Albedo, Provider, Reply, text


class DaemonTest(unittest.TestCase):
    def test_history_pages_recover_older_turns_once(self):
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            for message in ("oldest prompt", "middle prompt", "newest prompt"):
                app.prompt(session, message).close()
                app.idle(session)

            pages = []
            before = None
            while True:
                suffix = "" if before is None else f"&before={before}"
                with app.api(f"/sessions/{session}/history?rows=2{suffix}") as response:
                    page = json.load(response)
                pages.append(page)
                if not page["more"]:
                    break
                self.assertIsInstance(page["before"], int)
                self.assertNotEqual(page["before"], before)
                before = page["before"]

            prompts = [
                [event["text"] for event in page["events"] if event["type"] == "user"]
                for page in pages
            ]
            self.assertEqual(
                [turn for turn in prompts if turn],
                [["newest prompt"], ["middle prompt"], ["oldest prompt"]],
            )
            self.assertFalse(pages[-1]["more"])

    def test_a_thoughts_duration_is_kept_with_the_transcript(self):
        # summarized thinking streams once it is written: here the response
        # opens, thinks 0.6s, and its summary comes 0.3s before the answer,
        # so the thought is timed from the opening, not the summary
        chunk = lambda delta, finish=None: {"id": "fixture", "choices": [
            {"index": 0, "delta": delta, "finish_reason": finish}]}
        reply = Reply("text", delay=0.3, events=[
            chunk({"role": "assistant"}),
            chunk({"reasoning_content": "weighing it"}),
            chunk({"content": "answer"}),
            chunk({}, "stop"),
        ])
        provider = Provider(lambda _request: reply)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "think first").close()
            app.idle(session)

            for source, events in (("stream", app.events(session)), ("history", app.history(session)["events"])):
                thoughts = [event for event in events if event["type"] == "thinking"]
                self.assertEqual([event["text"] for event in thoughts], ["weighing it"], source)
                self.assertGreaterEqual(thoughts[0].get("elapsedMs", 0), 500, source)


if __name__ == "__main__":
    unittest.main()
