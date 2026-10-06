"""Concurrent child kernel boot stays responsive and forwards all answers."""

import json
import os
import sqlite3
import sys
import time
import unittest
import urllib.error

from harness import (
    Albedo,
    Provider,
    exclusive,
    operation_id,
    python,
    release_fifo,
    text,
    wait_until,
)

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

    @exclusive
    def test_closed_child_does_not_start_when_its_kernel_finishes_booting(self):
        def script(request):
            if request["messages"][-1].get("role") != "user":
                return text("done")
            if user_text(request) == "spawn held child":
                return python(
                    "models = await agents.models()\n"
                    "child = await agents.self.spawn('held task', name='held', model=models[0])\n"
                    "print(child.id)"
                )
            if user_text(request) == "close held child":
                return python(
                    "await child.close()\nprint((await mail.submit(child, 'late task')).status)"
                )
            return text("done")

        def prepare(app):
            # The parent boots normally; creating this FIFO holds later launches.
            wrapper = app.home / "bin" / "python3"
            wrapper.parent.mkdir()
            gate = app.workspace / "boot-gate"
            wrapper.write_text(
                f"#!{sys.executable}\n"
                "import os, sys\n"
                "from pathlib import Path\n"
                f"gate = Path({str(gate)!r})\n"
                "if ('launch' in sys.argv or 'start' in sys.argv) and gate.exists():\n"
                f"    Path({str(app.workspace / 'boot-ready')!r}).touch()\n"
                "    with gate.open('rb') as reader: reader.read(1)\n"
                f"os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n"
            )
            wrapper.chmod(0o700)
            app.env["PATH"] = str(wrapper.parent) + os.pathsep + app.env["PATH"]

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider, prepare=prepare) as app:
            parent = app.session()
            app.prompt(parent, "prime parent kernel").close()
            app.idle(parent)
            gate = app.workspace / "boot-gate"
            os.mkfifo(gate)
            app.prompt(parent, "spawn held child").close()
            app.idle(parent)
            with app.api(f"/sessions?scope=all&family_id={parent}") as response:
                child = next(
                    item["id"]
                    for item in json.load(response)["items"]
                    if item["parent_id"] == parent
                )
            with sqlite3.connect(app.home / "albedo.sqlite") as database:
                self.assertEqual(
                    database.execute(
                        "SELECT count(*) FROM mail WHERE recipient=? AND delivered_at IS NULL",
                        (child,),
                    ).fetchone()[0],
                    1,
                )
            self.assertEqual(app.history(child)["items"], [])
            wait_until(
                (app.workspace / "boot-ready").exists, 10, "child did not start booting"
            )
            app.prompt(parent, "close held child").close()
            app.idle(parent)
            wait_until(
                lambda: release_fifo(gate), 10, "child did not reach its boot gate"
            )
            gate.unlink()
            # Wait for the child's preparation to finish, not an arbitrary sleep.
            app.idle(child)
            self.assertEqual(app.history(child)["items"], [])
            with sqlite3.connect(app.home / "albedo.sqlite") as database:
                self.assertIsNotNone(
                    database.execute(
                        "SELECT closed_at FROM session_family WHERE session=?",
                        (child,),
                    ).fetchone()[0]
                )
                self.assertEqual(
                    database.execute(
                        "SELECT count(*) FROM mail WHERE recipient=? AND delivered_at IS NULL",
                        (child,),
                    ).fetchone()[0],
                    2,
                )
            self.assertFalse(
                any(
                    "held task" in user_text(record["request"])
                    for record in provider.requests
                )
            )
            # A manual chat can still visit a closed child without consuming its letters.
            app.prompt(child, "manual visit").close()
            app.idle(child)
            self.assertTrue(
                any(
                    user_text(record["request"]) == "manual visit"
                    for record in provider.requests
                )
            )
            # Closing one child must not prevent a later sibling from starting.
            sibling = operation_id()
            with app.api(
                f"/sessions/{sibling}",
                {
                    "kind": "child",
                    "parent_id": parent,
                    "address": "sibling",
                    "name": "sibling",
                    "initial_input_id": operation_id(),
                    "task": "normal task",
                },
                method="PUT",
                headers={"If-None-Match": "*"},
            ) as response:
                self.assertEqual(json.load(response)["id"], sibling)
            app.idle(sibling)
            self.assertTrue(
                any(
                    "normal task" in user_text(record["request"])
                    for record in provider.requests
                )
            )

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
                    and (item.get("mail") or {}).get("kind") == "unreviewed"
                    for item in items
                )
            )
        return counts
