"""Transcript paging across turns through the real daemon."""
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


if __name__ == "__main__":
    unittest.main()
