"""The newest end of a long transcript is what a client sees first."""

import json
import unittest

from harness import Albedo, Provider, python, text

ROUNDS = 8


class TranscriptTailTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            results = [m for m in request["messages"] if m.get("role") == "tool"]
            if len(results) < ROUNDS:
                return python(f"{len(results)}", reasoning=f"step {len(results)}")
            return text("all rounds done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def read(self, path):
        return json.loads(self.app.api(path).read())

    def test_a_short_tail_ends_at_the_newest_entry_and_pages_back_whole(self):
        session = self.app.session()
        self.app.prompt(session, "run the rounds").close()
        self.app.idle(session)
        everything = self.read(f"/sessions/{session}/history?limit=200")
        self.assertIsNone(everything["older"])
        full = [entry["id"] for entry in everything["items"]]

        # a thought and its tool call share a row, so ten rows hold more
        # than ten entries; the page keeps the newest ones
        tail = self.read(f"/sessions/{session}?tail=10")["history"]
        shown = [entry["id"] for entry in tail["items"]]
        self.assertTrue(shown and len(shown) <= 10, shown)
        self.assertEqual(shown, full[-len(shown) :])
        self.assertIsNone(tail["newer"])

        # older pages continue from there without gaps or repeats
        seen = shown
        older = tail["older"]
        while older is not None:
            page = self.read(f"/sessions/{session}/history?limit=10&next={older}")
            seen = [entry["id"] for entry in page["items"]] + seen
            older = page["older"]
        self.assertEqual(seen, full)


if __name__ == "__main__":
    unittest.main()
