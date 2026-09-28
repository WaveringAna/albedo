"""Agent families: spawn, forwarding, addressing, snapshots, and routing."""

import json
import threading
import time
import unittest
import urllib.error
import urllib.request

from harness import Albedo, Provider, text


def user_message(request):
    return next(
        (
            item.get("content", "")
            for item in reversed(request["messages"])
            if item.get("role") == "user"
        ),
        "",
    )


def wait_for(predicate, timeout=40):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.05)
    raise AssertionError("agent event never arrived")


class AgentsTests(unittest.TestCase):
    def setUp(self):
        def answer(request):
            user = user_message(request)
            line = user.splitlines()[-2 if "</mail>" in user else -1]
            return text("answered: " + line)

        self.provider = Provider(answer)
        self.alpha = f"alpha-{self.provider.route}"
        self.beta = f"beta-{self.provider.route}"
        providers = {
            profile: {
                "baseUrl": self.provider.url + f"/{name}/v1",
                "apiKey": "key",
                "model": f"fixture-{name}-{self.provider.route}",
                "protocol": "chat_completions",
            }
            for profile, name in ((self.alpha, "alpha"), (self.beta, "beta"))
        }

        # The cached catalog lists a model for the fixture endpoint that no profile names.
        def prepare(app):
            (app.home / "models.json").write_text(
                json.dumps(
                    {
                        "fixture-gateway": {
                            "api": "http://127.0.0.1/v1",
                            "env": [],
                            "models": {"fixture-listed": {"id": "fixture-listed"}},
                        }
                    }
                )
            )

        self.app = Albedo(self.provider, providers=providers, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.provider.close)
        self.addCleanup(self.app.__exit__, None, None, None)

    def api(self, path, body=None, method=None):
        with self.app.api(path, body, method=method) as response:
            return json.load(response)

    def asked(self, fragment):
        return [
            user_message(record["request"])
            for record in self.provider.requests
            if fragment in user_message(record["request"])
        ]

    def spawn(self, parent, name="coder", task="map every wake path", model=None):
        body = {"name": name, "task": task}
        if model is not None:
            body["model"] = model
        return self.api(f"/sessions/{parent}/children", body)

    def listen(self):
        heard = []
        ready = threading.Event()

        def consume():
            request = urllib.request.Request(
                self.app.base + "/agents/stream",
                headers={"Authorization": "Bearer " + self.app.connection["token"]},
            )
            with urllib.request.urlopen(request, timeout=30) as response:
                for raw in response:
                    if raw.startswith(b"data: "):
                        heard.extend(json.loads(raw[6:])["events"])
                        ready.set()

        threading.Thread(target=consume, daemon=True).start()
        self.assertTrue(
            ready.wait(timeout=2), "agent stream did not send its initial frame"
        )
        return heard

    def test_spawn_task_and_unreviewed_forward(self):
        parent = self.app.session()
        made = self.spawn(parent)
        child = made["session"]["id"]
        self.assertEqual(
            made["member"],
            {
                "session": child,
                "parent": parent,
                "name": "coder",
                "depth": 1,
                "closed": False,
            },
        )
        self.assertEqual(made["session"]["title"], "coder")
        self.assertNotIn(child, [s["id"] for s in self.api("/sessions")])
        task = wait_for(lambda: self.asked('kind="task"'))[0]
        self.assertIn(f'session="{parent}"', task)
        self.assertIn("map every wake path", task)
        forwarded = wait_for(lambda: self.asked('kind="unreviewed"'))[0]
        self.assertIn('from="coder"', forwarded)
        self.assertIn("answered: map every wake path", forwarded)
        self.app.idle(parent)
        self.app.idle(child)
        self.assertEqual(
            [m["name"] for m in self.api(f"/sessions/{parent}/children")], ["coder"]
        )

    def test_tree_snapshot_and_event_stream(self):
        parent = self.app.session()
        heard = self.listen()
        child = self.spawn(parent)["session"]["id"]
        wait_for(lambda: self.asked('kind="unreviewed"'))
        for asker in (parent, child):
            tree = self.api(f"/agents?session={asker}")
            self.assertEqual(tree["root"], parent)
            self.assertEqual(
                [(n["parent"], n["depth"]) for n in tree["nodes"]],
                [(None, 0), (parent, 1)],
            )
            self.assertEqual(tree["nodes"][1]["name"], "coder")
        expected = {
            ("spawn", child),
            ("mail", child),
            ("mail", parent),
            ("running", child),
            ("running", parent),
            ("text", child),
        }

        def kinds():
            return {(e["type"], e.get("session") or e.get("to")) for e in list(heard)}

        try:
            wait_for(lambda: expected <= kinds(), timeout=10)
        except AssertionError:
            self.fail(f"missing stream events: {expected - kinds()}; got {kinds()}")

    def test_rename_keeps_family_address_and_reports_stream_event(self):
        parent = self.app.session()
        child = self.spawn(parent)["session"]["id"]
        self.app.idle(child)
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        heard = self.listen()
        renamed = self.api(
            f"/sessions/{child}", {"name": "  wake path\naudit "}, "PATCH"
        )
        self.assertEqual(renamed["title"], "wake path audit")
        self.assertEqual(
            self.api(f"/sessions/{parent}", {"name": "orchestration"}, "PATCH")[
                "title"
            ],
            "orchestration",
        )
        self.assertEqual(
            [s["title"] for s in self.api("/sessions") if s["id"] == parent],
            ["orchestration"],
        )
        nodes = {
            n["session"]["id"]: n
            for n in self.api(f"/agents?session={parent}")["nodes"]
        }
        self.assertEqual(
            (nodes[parent]["name"], nodes[parent]["address"]), ("orchestration", None)
        )
        self.assertEqual(
            (nodes[child]["name"], nodes[child]["address"]),
            ("wake path audit", "coder"),
        )
        try:
            wait_for(
                lambda: any(
                    e["type"] == "renamed"
                    and e["session"] == child
                    and e["name"] == "wake path audit"
                    for e in list(heard)
                ),
                timeout=10,
            )
        except AssertionError:
            self.fail(f"rename stream missing: {heard!r}")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.api("/sessions/no-such-session", {"name": "x"}, "PATCH")
        self.assertEqual(caught.exception.code, 409)
        receipt = self.api(
            f"/sessions/{parent}/mail", {"to": "coder", "body": "also cover schedules"}
        )
        self.assertEqual((receipt["to"], receipt["name"]), (child, "coder"))
        self.assertIn(receipt["status"], ("delivered", "queued"))
        wait_for(lambda: self.asked("also cover schedules"))
        wait_for(lambda: len(self.asked('kind="unreviewed"')) == 2)
        self.app.idle(parent)

    def test_reply_and_external_id_mail(self):
        parent = self.app.session()
        radio = self.app.session()
        child = self.spawn(parent)["session"]["id"]
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        before = len(self.provider.requests)
        receipt = self.api(
            f"/sessions/{child}/mail", {"to": "parent", "body": "schedules covered"}
        )
        self.assertEqual(receipt["to"], parent)
        wait_for(lambda: self.asked("schedules covered"))
        self.app.idle(parent)
        time.sleep(1)
        self.assertEqual(len(self.provider.requests), before + 1)
        with self.assertRaises(urllib.error.HTTPError):
            self.api(f"/sessions/{child}/mail", {"to": "radio", "body": "by name"})
        receipt = self.api(
            f"/sessions/{child}/mail", {"to": radio, "body": "deploy when green"}
        )
        self.assertEqual(receipt["status"], "pending")
        wait_for(lambda: self.asked("deploy when green"), timeout=40)
        self.app.idle(radio)

    def test_tree_deletion_and_renamed_workspace(self):
        parent = self.app.session()
        child = self.spawn(parent)["session"]["id"]
        wait_for(lambda: self.asked('kind="unreviewed"'))
        self.app.idle(parent)
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.api(f"/sessions/{parent}", method="DELETE")
        self.assertEqual(caught.exception.code, 409)
        self.assertIn("child", caught.exception.read().decode())
        self.assertEqual(
            self.api(f"/sessions/{parent}?tree=1", method="DELETE")["deleted"], 2
        )
        listed = [s["id"] for s in self.api("/sessions")]
        self.assertNotIn(parent, listed)
        self.assertNotIn(child, listed)
        radio = self.app.session()
        self.api(f"/sessions/{radio}", {"name": "radio desk"}, "PATCH")
        moved = self.app.root / "moved"
        moved.mkdir()
        self.assertEqual(
            self.api(f"/sessions/{radio}/workspace", {"workspace": str(moved)})[
                "title"
            ],
            "radio desk",
        )
        self.assertEqual(
            [s["title"] for s in self.api("/sessions") if s["id"] == radio],
            ["radio desk"],
        )

    def test_qualified_and_inferred_cross_provider_models(self):
        parent = self.app.session()
        self.api(f"/sessions/{parent}", {"name": "radio desk"}, "PATCH")
        with self.assertRaises(urllib.error.HTTPError) as caught:
            self.spawn(
                parent, "missing", "should not run", f"{self.beta}/no-such-model"
            )
        self.assertEqual(caught.exception.code, 409)
        for name, model in (
            ("explicit", f"{self.beta}/fixture-beta-{self.provider.route}"),
            ("inferred", f"fixture-beta-{self.provider.route}"),
        ):
            made = self.spawn(parent, name, "cross-provider task", model)
            self.assertEqual(made["session"]["provider"], self.beta)
            self.assertEqual(
                made["session"]["model"], f"fixture-beta-{self.provider.route}"
            )
            self.assertEqual(made["member"]["parent"], parent)
            self.app.idle(made["session"]["id"])
        tasks = wait_for(
            lambda: self.asked('kind="task">\ncross-provider')
            if len(self.asked('kind="task">\ncross-provider')) == 2
            else None
        )
        self.assertTrue(all('from="radio desk"' in task for task in tasks))
        self.assertGreaterEqual(
            sum("/beta/" in r["path"] for r in self.provider.requests), 2
        )

    def test_generic_profile_lists_its_endpoints_catalog_models(self):
        parent = self.app.session()
        made = self.spawn(
            parent, "listed", "catalog task", f"{self.beta}/fixture-listed"
        )
        self.assertEqual(
            (made["session"]["provider"], made["session"]["model"]),
            (self.beta, "fixture-listed"),
        )
        self.app.idle(made["session"]["id"])


if __name__ == "__main__":
    unittest.main()
