"""The prompt-cache warmer: an idle session whose children still run re-sends
its last request with a tiny output budget before the provider cache would
expire.

Catches: pings that rebuild the request instead of repeating the one the turn
sent (which would compact or summarize), ping request rows that do not carry
the turn's prefix identity, pings that commit or publish anything, warming
that never stops at its budget, warming that continues after the waking work
finished, and a submit that cannot get through while a ping holds the session.
None of this is observable from the transcript alone; the provider and the
request rows are the witnesses.
"""

import json
import threading
import time
import unittest

from harness import Albedo, Provider, exclusive, text

# A prefix big enough to matter: 4096 cached tokens against the 1024 floor.
PARENT_USAGE = {
    "input_tokens": 6000,
    "output_tokens": 4,
    "input_tokens_details": {"cached_tokens": 4096},
}
CHILD_USAGE = {
    "input_tokens": 300,
    "output_tokens": 4,
    "input_tokens_details": {"cached_tokens": 100},
}

TASK = "hold the fort until released"


# A local cache-table override matching the fixture host: the shortest refresh
# TTL the table can say, bought at 1.0x and read at 0.3x, so pings come 0.9s
# apart and at most floor(1.0 / 0.3) - 1 = 2 of them pay for themselves.
TTL_SECONDS = 1
# Longer than a ping interval by more than a loaded machine's jitter: a ping
# that was due would have gone out within it.
QUIET_SECONDS = 2 * TTL_SECONDS
CACHE_TTL = {
    "version": 1,
    "entries": [
        {
            "id": "fixture",
            "match": {"host": "127.0.0.1"},
            "policy": "refresh",
            "clock": "request",
            "tiers": [{"seconds": TTL_SECONDS, "write": 1.0}],
            "read": 0.3,
            "evidence": "measured",
        }
    ],
}


def wait_for(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("warming never arrived")


class WarmTest(unittest.TestCase):
    def setUp(self):
        # The child's turn blocks here until the test releases it, so the
        # parent sits idle on work that will wake it.
        self.gate = threading.Event()
        self.provider = Provider(self.reply)
        providers = {
            "orchestrator": {
                "baseUrl": self.provider.url + "/parent/v1",
                "apiKey": "key",
                "model": "fixture-model",
                "protocol": "responses",
            },
            "scout": {
                "baseUrl": self.provider.url + "/child/v1",
                "apiKey": "key",
                "model": "scout-model",
                "protocol": "responses",
            },
        }

        def prepare(app):
            (app.home / "cache-ttl.json").write_text(json.dumps(CACHE_TTL))
            app.write_extensions(
                {"enabled": {"warm": True}, "warm": {"minCachedTokens": 1024}}
            )

        self.app = Albedo(
            self.provider, protocol="responses", providers=providers, prepare=prepare
        )
        self.app.__enter__()
        self.addCleanup(self.provider.close)
        self.addCleanup(self.app.__exit__, None, None, None)
        # A failed test must not leave the scout's request blocked.
        self.addCleanup(self.gate.set)

    def reply(self, request):
        if TASK in json.dumps(request):
            self.gate.wait(timeout=90)
            return text("scout finished", usage=CHILD_USAGE)
        return text("orchestrator reply", usage=PARENT_USAGE)

    def api(self, path, body=None, method=None):
        with self.app.api(path, body, method=method) as response:
            return json.load(response)

    def requests(self, fragment):
        return [
            record["request"]
            for record in self.provider.requests
            if fragment in record["path"]
        ]

    def pings(self, session_requests):
        return [
            request for request in session_requests if "max_output_tokens" in request
        ]

    def rows(self, session):
        with self.app.api(f"/sessions/{session}/requests") as response:
            return json.load(response)["rows"]

    def tree(self, session):
        items, after = [], 0
        while True:
            with self.app.api(
                f"/sessions/{session}/tree?after={after}&limit=100"
            ) as response:
                page = json.load(response)
            items.extend(page["items"])
            if not page["hasMore"]:
                return items
            after = page["nextCursor"]

    def swarm(self, parent=None):
        """A parent whose turn has run while its scout is still working."""
        parent = parent or self.app.session()
        made = self.api(
            f"/sessions/{parent}/children",
            {"name": "scout", "task": TASK, "model": "scout/scout-model"},
        )
        child = made["member"]["session"]
        wait_for(lambda: self.requests("/child/") or None)
        self.app.prompt(parent, "run the swarm").close()
        self.app.idle(parent)
        return parent, child

    def assert_no_pings(self, parent, child):
        time.sleep(QUIET_SECONDS)
        self.assertEqual(len(self.requests("/parent/")), 1)
        self.assertEqual([row["kind"] for row in self.rows(parent)], ["turn"])

    @exclusive
    def test_the_warmer_is_off_unless_enabled(self):
        settings = json.loads((self.app.home / "extensions.json").read_text())
        del settings["enabled"]["warm"]
        (self.app.home / "extensions.json").write_text(json.dumps(settings))
        self.assert_no_pings(*self.swarm())

    @exclusive
    def test_a_session_that_disables_the_warmer_is_not_pinged(self):
        parent = self.app.session()
        extensions = self.api(
            f"/sessions/{parent}/extensions", {"name": "warm", "enabled": False}
        )
        self.assertFalse(
            next(item["enabled"] for item in extensions if item["name"] == "warm")
        )
        self.assert_no_pings(*self.swarm(parent))

    @exclusive
    def test_pings_repeat_the_last_request_and_stop_at_the_budget(self):
        parent, child = self.swarm()
        before = self.tree(parent)

        def two_pings():
            found = self.pings(self.requests("/parent/"))
            return found if len(found) == 2 else None

        pings = wait_for(two_pings)
        turn = self.requests("/parent/")[0]
        for ping in pings:
            # A ping is the turn's request as sent, with only the output
            # budget lowered — the Responses protocol's minimum.
            self.assertEqual(ping, {**turn, "max_output_tokens": 16})

        # The request rows carry the same prefix identity and cache marks as
        # the turn they repeat, and never a transcript row of their own.
        rows = self.rows(parent)
        self.assertEqual(
            [row["kind"] for row in rows], ["turn", "background", "background"]
        )
        head = rows[0]
        for row in rows[1:]:
            self.assertEqual(row["headHash"], head["headHash"])
            self.assertEqual(row["inputs"], head["inputs"])
            self.assertEqual(row["replaced"], head["replaced"])
            self.assertEqual(row["projectionHash"], head["projectionHash"])
            self.assertEqual(row["cacheMarks"], head["cacheMarks"])
            self.assertEqual(row["cachedInputTokens"], 4096)
            self.assertIsNone(row["seq"])
            self.assertEqual(row["outcome"], "ok")
            self.assertEqual(row["profile"], "orchestrator")
            self.assertEqual(row["model"], "fixture-model")
        # A ping paid 4096 cached tokens: the hit the TTL model predicted.
        # Each ping is due an interval after the send before it, timed from
        # the moment the warmer sent it, which its request row stamps a little
        # later: rows apart from the turn's are bounded from the turn's.
        interval = TTL_SECONDS * 900
        self.assertGreaterEqual(rows[1]["startedMs"], rows[0]["startedMs"] + interval)
        self.assertGreaterEqual(
            rows[2]["startedMs"], rows[0]["startedMs"] + 2 * interval
        )

        # The transcript is untouched by warming.
        self.assertEqual(self.tree(parent), before)

        # The budget is spent: no third ping past another interval.
        time.sleep(QUIET_SECONDS)
        self.assertEqual(len(self.pings(self.requests("/parent/"))), 2)

        # Once the scout finishes, nothing new is scheduled either.
        self.gate.set()
        self.app.idle(child)
        self.app.idle(parent)
        time.sleep(QUIET_SECONDS)
        self.assertEqual(len(self.pings(self.requests("/parent/"))), 2)
        # The scout's answer woke the parent with an ordinary turn.
        turns = [
            request
            for request in self.requests("/parent/")
            if "max_output_tokens" not in request
        ]
        self.assertEqual(len(turns), 2)
        self.assertIn("scout finished", json.dumps(turns[1]))

    @exclusive
    def test_a_ping_restarts_the_cached_counts_fade(self):
        parent, child = self.swarm()

        def fades():
            return [
                event["cacheFade"]
                for event in self.app.events(parent)
                if event["type"] == "usage"
            ]

        # The fixture's clock counts the TTL from the send's start; nothing is
        # left after it.
        turn = self.rows(parent)[0]
        expires = turn["startedMs"] + TTL_SECONDS * 1000
        self.assertEqual(fades()[0], [{"at": expires, "cached": 0}])

        # A ping resends the prefix, so the provider's clock starts over from
        # it: the fade moves to the ping's send, which the session times from
        # just before the request row does.
        ping = wait_for(
            lambda: next(
                (row for row in self.rows(parent) if row["kind"] == "background"), None
            )
        )
        moved = wait_for(
            lambda: next(
                (step["at"] for step in fades()[-1] if step["at"] != expires), None
            )
        )
        self.assertLessEqual(moved, ping["startedMs"] + TTL_SECONDS * 1000)
        self.assertGreater(moved, ping["startedMs"] + TTL_SECONDS * 1000 - 500)
        self.gate.set()
        self.app.idle(child)
        self.app.idle(parent)

    @exclusive
    def test_a_submit_during_warming_answers_and_warming_ends_with_the_children(self):
        parent, child = self.swarm()

        first = wait_for(lambda: self.pings(self.requests("/parent/")) or None)
        turn = self.requests("/parent/")[0]
        self.assertEqual(first[0], {**turn, "max_output_tokens": 16})

        # A real submit while warming gets through and is answered normally.
        self.app.prompt(parent, "real work now").close()
        self.app.idle(parent)
        self.assertIn(
            "orchestrator reply", [item["preview"] for item in self.tree(parent)]
        )

        # The work that kept the parent warm is done; warming ends with it.
        self.gate.set()
        self.app.idle(child)
        self.app.idle(parent)
        settled = len(self.pings(self.requests("/parent/")))
        time.sleep(QUIET_SECONDS)
        self.assertEqual(len(self.pings(self.requests("/parent/"))), settled)
        # Every ping that did go out repeated a turn's request, budget aside.
        turns = [
            request
            for request in self.requests("/parent/")
            if "max_output_tokens" not in request
        ]
        for ping in self.pings(self.requests("/parent/")):
            self.assertIn(
                ping, [{**repeated, "max_output_tokens": 16} for repeated in turns]
            )
