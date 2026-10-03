"""Concurrent child kernel boot stays responsive and forwards all answers."""

import json
import os
import time
import unittest
import urllib.error

from harness import Albedo, Provider, operation_id, python, text

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
                        child = operation_id()
                        with app.api(
                            f"/sessions/{child}",
                            {
                                "kind": "child",
                                "parent_id": root,
                                "address": f"sp-{number}",
                                "name": f"sp-{number}",
                                "initial_input_id": operation_id(),
                                "task": f"count to {number}",
                            },
                            method="PUT",
                            headers={"If-None-Match": "*"},
                        ) as response:
                            self.assertEqual(json.load(response)["id"], child)
                        children.append(child)
                self.assertLess(
                    time.monotonic() - started, 30, "spawn must not await kernel boot"
                )
                slowest = 0.0
                deadline = time.monotonic() + 300
                while time.monotonic() < deadline:
                    answers = self.answers(app, roots)
                    tick = time.monotonic()
                    for root in roots:
                        with app.api(
                            f"/sessions?scope=all&family_id={root}"
                        ) as response:
                            self.assertEqual(
                                len(json.load(response)["items"]), CHILDREN + 1
                            )
                    for child in children[::6]:
                        with app.api(f"/sessions/{child}?tail=0") as response:
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
                with app.api("/server") as response:
                    self.assertEqual(json.load(response)["state"], "ready")
        finally:
            provider.close()

    def test_explicit_session_provider_binds_and_unknown_profile_is_rejected(self):
        provider = Provider(lambda _request: text("ok"))
        try:
            with Albedo(provider) as app:
                session = app.session()
                with app.api("/sessions") as response:
                    info = next(
                        item
                        for item in json.load(response)["items"]
                        if item["id"] == session
                    )
                self.assertEqual(info["provider_profile"], app.profile)
                with self.assertRaises(urllib.error.HTTPError) as rejected:
                    app.api(
                        f"/sessions/{operation_id()}",
                        {
                            "kind": "new",
                            "workspace": str(app.workspace),
                            "provider_profile": "not-configured",
                        },
                        method="PUT",
                        headers={"If-None-Match": "*"},
                    ).close()
                self.assertEqual(rejected.exception.code, 400)
        finally:
            provider.close()

    @staticmethod
    def answers(app, roots):
        counts = []
        for root in roots:
            with app.api(f"/sessions/{root}/history?limit=200") as response:
                items = json.load(response)["items"]
            counts.append(
                sum(
                    item["kind"] == "user"
                    and any(
                        part["kind"] == "text" and "unreviewed" in part["text"]
                        for part in item["content"]
                    )
                    for item in items
                )
            )
        return counts
