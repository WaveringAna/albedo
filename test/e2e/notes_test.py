"""The model's own notes survive each compaction and lead every later request."""

import json
import unittest

from harness import Albedo, Provider, error, text

MARKER = "keeping notes for yourself"
EVICTED = "<newly-evicted-history>"


def last_user(request):
    return next(
        (
            str(item.get("content", ""))
            for item in reversed(request["input"])
            if item.get("role") == "user"
        ),
        "",
    )


class NotesTests(unittest.TestCase):
    def setUp(self):
        self.written = []
        self.notes_fail = False

        def reply(request):
            if MARKER in request.get("instructions", ""):
                if self.notes_fail:
                    return error(500)
                return text(self.written.pop(0))
            if EVICTED in last_user(request):
                return text("rolling summary")
            return text("done")

        self.provider = Provider(reply)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def say(self, *prompts):
        for prompt in prompts:
            self.app.prompt(self.session, prompt).close()
            self.app.idle(self.session)

    def compact(self):
        with self.app.api(f"/sessions/{self.session}/compaction", {}) as response:
            self.assertEqual(json.load(response)["state"], "compacted")
        self.app.idle(self.session)

    def note_calls(self):
        return [
            item["request"]
            for item in self.provider.requests
            if MARKER in item["request"].get("instructions", "")
        ]

    def head_of_next_request(self):
        self.say("next")
        return self.provider.requests[-1]["request"]["input"][0]["content"]

    def test_notes_are_rewritten_from_the_previous_ones_and_lead_each_request(self):
        self.written = ["NOTES-ONE commit abc123", "NOTES-TWO"]
        self.say("first question", "second question", "third question")
        self.compact()

        (first,) = self.note_calls()
        self.assertIn("at most 2000 tokens", first["instructions"])
        self.assertIn("(none)", last_user(first))
        self.assertIn("first question", last_user(first))
        self.assertIn("[assistant]\ndone", last_user(first))
        self.assertNotIn("provider item", last_user(first))
        head = self.head_of_next_request()
        self.assertIn("compaction notes", head)
        self.assertIn("NOTES-ONE commit abc123", head)

        self.say("fourth question", "fifth question")
        self.compact()

        second = self.note_calls()[1]
        previous, evicted = last_user(second).split(EVICTED)
        self.assertIn("NOTES-ONE commit abc123", previous)
        self.assertIn("fourth question", evicted)
        self.assertNotIn("first question", evicted)
        head = self.head_of_next_request()
        self.assertIn("NOTES-TWO", head)
        self.assertNotIn("NOTES-ONE", head)

    def test_a_failed_rewrite_keeps_the_old_notes_and_the_compaction(self):
        self.written = ["NOTES-ONE"]
        self.say("first question", "second question", "third question")
        self.compact()
        self.say("fourth question", "fifth question")
        self.notes_fail = True
        self.compact()

        self.assertEqual(len(self.note_calls()), 2)
        head = self.head_of_next_request()
        self.assertIn("NOTES-ONE", head)
        request = self.provider.requests[-1]["request"]
        self.assertIn("rolling summary", json.dumps(request["input"]))


if __name__ == "__main__":
    unittest.main()
