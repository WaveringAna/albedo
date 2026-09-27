"""Transcript paging and what the transcript keeps, through the real daemon."""
import json
import unittest

from harness import Albedo, Provider, text


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
        # the reply streams a chunk every 0.2s, so the thought runs that long
        # before the answer's first chunk ends it
        provider = Provider(lambda _request: text("answer", reasoning="weighing it", delay=0.2))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "think first").close()
            app.idle(session)

            for source, events in (("stream", app.events(session)), ("history", app.history(session)["events"])):
                thoughts = [event for event in events if event["type"] == "thinking"]
                self.assertEqual([event["text"] for event in thoughts], ["weighing it"], source)
                self.assertGreaterEqual(thoughts[0].get("elapsedMs", 0), 150, source)


if __name__ == "__main__":
    unittest.main()
