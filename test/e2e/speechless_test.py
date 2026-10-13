"""A turn that ends with only reasoning, or nothing at all, and no tool call.

Catches: such a turn ending silently (the user sees nothing and the agent
stops mid-task), and the identical request being sent again, which buys
another full reasoning pass that likely ends the same way. Gemini routes do
this now and then; only the real loop decides what happens next.
"""

import json
import unittest

from harness import Albedo, Provider, text

NUDGE = "your previous response ended with no reply and no tool call"


def nudged(request):
    return NUDGE in json.dumps(request["input"][-1])


class SpeechlessTurnTest(unittest.TestCase):
    def run_turn(self, script):
        provider = Provider(script)
        with Albedo(provider, protocol="responses") as app:
            session = app.session()
            app.prompt(session, "what now").close()
            snapshot = app.idle(session)
            history = json.dumps(app.history(session))
        errors = [
            line["text"]
            for line in snapshot["activity"]["lines"]
            if line["kind"] == "error"
        ]
        return provider.requests, history, errors

    def test_a_turn_with_only_reasoning_is_asked_once_for_its_answer(self):
        requests, history, errors = self.run_turn(
            lambda request: (
                text("the answer")
                if nudged(request)
                else text("", reasoning="pondering quietly")
            )
        )
        self.assertEqual(len(requests), 2)
        self.assertFalse(nudged(requests[0]["request"]))
        # The nudge goes out after the same history, never kept in it.
        self.assertEqual(
            requests[1]["request"]["input"][:-1], requests[0]["request"]["input"]
        )
        self.assertIn("the answer", history)
        self.assertNotIn(NUDGE, history)
        self.assertEqual(errors, [])

    def test_a_model_that_stays_silent_ends_the_turn_with_an_error(self):
        requests, _, errors = self.run_turn(
            lambda _request: text("", reasoning="pondering quietly")
        )
        self.assertEqual(len(requests), 2)
        self.assertEqual(
            errors,
            [
                "fixture-model ended its turn without a reply or a tool call, even"
                " when asked again; send a message to continue"
            ],
        )


if __name__ == "__main__":
    unittest.main()
