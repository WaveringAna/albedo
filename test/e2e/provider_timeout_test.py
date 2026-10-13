"""Provider timeouts: where a call was when its budget ran out decides how often
it is retried.

Catches: a call the provider accepted and then went silent on (a model thinking
past the budget, billed the whole time) being re-sent through the whole retry
ladder, the error that reaches the user not saying what happened, and request
rows that cannot tell a dead connection from a silent model. Only a real socket
that stalls before or after its headers shows these.
"""

import json
import unittest

from harness import Albedo, Provider, Reply, exclusive

BUDGET_MS = "1000"


def capped(app):
    app.env["ALBEDO_PROVIDER_TIMEOUT_MS"] = BUDGET_MS


@exclusive
class ProviderTimeoutTest(unittest.TestCase):
    def run_turn(self, reply):
        provider = Provider(lambda _request: reply)
        with Albedo(provider, protocol="responses", prepare=capped) as app:
            session = app.session()
            app.prompt(session, "think hard").close()
            snapshot = app.idle(session, timeout=90)
            with app.api(f"/sessions/{session}/context?view=requests") as response:
                rows = json.load(response)["items"]
        errors = [
            line["text"]
            for line in snapshot["activity"]["lines"]
            if line["kind"] == "error"
        ]
        return provider, rows, errors

    def test_a_model_silent_after_its_headers_is_retried_once(self):
        provider, rows, errors = self.run_turn(Reply("text", "never", hang=True))
        self.assertEqual(len(provider.requests), 2)
        self.assertEqual(len(rows), 2)
        for row in rows:
            self.assertEqual(row["outcome"], "failed")
            self.assertEqual(
                row["failure"]["detail"],
                "Timeout awaiting the first event after 1000 ms",
            )
            self.assertIsNotNone(row["first_byte_ms"])
            self.assertEqual(row["stream"]["events"], 0)
            self.assertIsNone(row["stream"]["first_event_ms"])
        self.assertEqual(
            errors,
            [
                "fixture-model produced no output for 1 s after the provider accepted"
                " the request; it may be thinking past the timeout. Try a lower"
                " effort, or retry"
            ],
        )

    def test_a_provider_that_never_answers_gets_the_whole_retry_ladder(self):
        provider, rows, errors = self.run_turn(Reply("text", "never", silent=True))
        self.assertEqual(len(provider.requests), 8)
        self.assertEqual(len(rows), 8)
        for row in rows:
            self.assertEqual(
                row["failure"]["detail"], "Timeout awaiting headers after 1000 ms"
            )
            self.assertIsNone(row["first_byte_ms"])
        self.assertEqual(
            errors,
            ["the provider request timed out awaiting headers (1 s) on every attempt"],
        )


if __name__ == "__main__":
    unittest.main()
