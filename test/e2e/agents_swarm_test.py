"""Concurrent child kernel boot stays responsive and forwards all answers."""

import json
import os
import time
import unittest
import urllib.error

from harness import Albedo, Provider, python, text

HEAVY = os.environ.get("ALBEDO_E2E_HEAVY") == "1"
ROOTS = 4 if HEAVY else 2
CHILDREN = 12 if HEAVY else 4


def user_text(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["messages"])
            if item.get("role") == "user"
        ),
        "",
    )


class AgentsSwarmTests(unittest.TestCase):
    def test_children_boot_without_blocking_actors_or_losing_answers(self):
        def script(request):
            last = request["messages"][-1]
            if last.get("role") == "user" and 'kind="task"' in user_text(request):
                return python("print('cell ran')")
            return text("done")

        provider = Provider(script)
        try:
            with Albedo(provider) as app:
                roots = [app.session() for _ in range(ROOTS)]
                children = []
                started = time.monotonic()
                for root in roots:
                    for number in range(CHILDREN):
                        with app.api(
                            f"/sessions/{root}/children",
                            {"name": f"sp-{number}", "task": f"count to {number}"},
                        ) as response:
                            children.append(json.load(response)["session"]["id"])
                self.assertLess(
                    time.monotonic() - started, 30, "spawn must not await kernel boot"
                )
                slowest = 0.0
                deadline = time.monotonic() + 300
                while time.monotonic() < deadline:
                    answers = self.answers(app, roots)
                    tick = time.monotonic()
                    for root in roots:
                        with app.api(f"/agents?session={root}") as response:
                            self.assertEqual(
                                len(json.load(response)["nodes"]), CHILDREN + 1
                            )
                    for child in children[::6]:
                        with app.api(f"/sessions/{child}/status") as response:
                            json.load(response)
                    slowest = max(slowest, time.monotonic() - tick)
                    if sum(answers) == ROOTS * CHILDREN:
                        break
                    time.sleep(0.5)
                self.assertEqual(self.answers(app, roots), [CHILDREN] * ROOTS)
                self.assertLess(
                    slowest, 5, "status and tree calls must stay responsive"
                )
                # Fast kernels can finish before the first status poll. Their
                # completed Python outputs prove every child actually booted.
                completed = [
                    record
                    for record in provider.requests
                    if record["request"]["messages"][-1].get("role") == "tool"
                    and "cell ran"
                    in record["request"]["messages"][-1].get("content", "")
                ]
                self.assertEqual(len(completed), ROOTS * CHILDREN)
                with app.api("/health") as response:
                    self.assertTrue(json.load(response)["ok"])
        finally:
            provider.close()

    def test_explicit_session_provider_binds_and_unknown_profile_is_rejected(self):
        provider = Provider(lambda _request: text("ok"))
        try:
            with Albedo(provider) as app:
                session = app.session()
                with app.api("/sessions") as response:
                    info = next(
                        item for item in json.load(response) if item["id"] == session
                    )
                self.assertEqual(info["provider"], app.profile)
                with self.assertRaises(urllib.error.HTTPError) as rejected:
                    app.api(
                        "/sessions",
                        {"workspace": str(app.workspace), "provider": "not-configured"},
                    ).close()
                self.assertEqual(rejected.exception.code, 400)
        finally:
            provider.close()

    @staticmethod
    def answers(app, roots):
        counts = []
        for root in roots:
            with app.api(f"/sessions/{root}/preview?limit=200") as response:
                items = json.load(response)["items"]
            counts.append(
                sum(
                    item["type"] == "user" and "unreviewed" in item["preview"]
                    for item in items
                )
            )
        return counts
