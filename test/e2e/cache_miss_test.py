"""A turn that reads far less cache than the call before it left is named, so the
chat can show it; one that reads what it should, or loses less than a provider's
own rounding, says nothing.

Catches: a miss that never reaches the usage the CLI draws, a loss inside the
rounding (or a small share of a big prompt) reported as a miss, and a call that
only follows a miss being blamed for it. The cache table's lifetime for the
fixture provider is a local file on the daemon's home, so this runs on a daemon
of its own.
"""

import json
import unittest

from harness import Albedo, Provider, exclusive, text


def usage(prompt, cached):
    return {
        "input_tokens": prompt,
        "output_tokens": 20,
        "input_tokens_details": {"cached_tokens": cached},
    }


# Each prompt asks for one call; (prompt tokens, cached tokens, expected miss).
# The expected miss is what the call lost from what the one before left cached,
# which for a provider that caches on its own is that call's whole prompt.
CALLS = {
    "a": (100_000, 90_000, None),
    "b": (101_000, 100_000, None),
    # 7k lost: under the floor, as a provider rounding its cache would lose.
    "c": (102_000, 94_000, None),
    # 32k lost of a 103k prompt.
    "d": (103_000, 70_000, 32_000),
    # The call after a miss reads what the miss left, so it loses nothing.
    "e": (104_000, 103_000, None),
}


def reply(request):
    user = next(
        (
            str(item.get("content", ""))
            for item in reversed(request["input"])
            if item.get("role") == "user"
        ),
        "",
    )
    prompt, cached, _ = CALLS.get(user, (1000, 0, None))
    return text(f"reply to {user}", usage=usage(prompt, cached))


@exclusive
class CacheMissTests(unittest.TestCase):
    def test_a_turn_names_the_cache_it_lost_and_only_that(self):
        provider = Provider(reply)
        try:
            with Albedo(provider, protocol="responses") as app:
                (app.home / "cache-ttl.json").write_text(
                    json.dumps(
                        {
                            "version": 1,
                            "entries": [
                                {
                                    "id": "fixture-evict",
                                    "match": {"host": "127.0.0.1"},
                                    "policy": "evict",
                                    "survival": {"typical": 600, "max": 3600},
                                    "evidence": "measured",
                                }
                            ],
                        }
                    )
                )
                session = app.session()
                seen = {}
                for prompt in CALLS:
                    app.prompt(session, prompt).close()
                    app.idle(session)
                    with app.api(f"/sessions/{session}?tail=0") as response:
                        seen[prompt] = json.load(response)["usage"].get(
                            "cache_miss_tokens"
                        )
                self.assertEqual(
                    seen, {prompt: miss for prompt, (_, _, miss) in CALLS.items()}
                )
        finally:
            provider.close()


if __name__ == "__main__":
    unittest.main()
