"""A Python crash injects exactly one reset notice without corrupting history; a
daemon crash leaves the detached kernel alive, so it injects none."""

import json
import urllib.error
import unittest

from harness import Albedo, Provider, exclusive, python, text

NOTICE = (
    "<system-note>The python kernel got reset and all variables are lost</system-note>"
)


def latest_user(request):
    return [item["content"] for item in request["input"] if item.get("role") == "user"][
        -1
    ]


# exclusive: crashes and restarts the daemon
@exclusive
class KernelResetTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            if request["input"][-1].get("role") == "user":
                prompt = latest_user(request)
                if prompt == "lose kernel":
                    return python("import os; os._exit(1)")
                if prompt == "recover kernel" + NOTICE:
                    return python("print('kernel-ready')")
            return text("ok")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses")
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def turn(self, session, prompt):
        self.app.prompt(session, prompt).close()
        self.app.idle(session)
        return latest_user(self.provider.requests[-1]["request"])

    def test_kernel_crash_emits_one_shot_reset_notice_and_daemon_crash_none(self):
        app = self.app
        session = app.session()
        self.assertEqual(self.turn(session, "first prompt"), "first prompt")
        unused = app.session()
        app.restart(crash=True)
        self.assertEqual(
            self.turn(unused, "unused session's first prompt"),
            "unused session's first prompt",
        )
        with self.assertRaises(urllib.error.HTTPError) as rejected:
            app.prompt(session, "   ").close()
        self.assertEqual(rejected.exception.code, 400)
        self.assertEqual(self.turn(session, "after restart"), "after restart")
        self.assertEqual(self.turn(session, "ordinary turn"), "ordinary turn")
        self.assertEqual(self.turn(session, "lose kernel"), "lose kernel")
        self.assertEqual(
            self.turn(session, "recover kernel"), "recover kernel" + NOTICE
        )
        self.assertTrue(
            any(
                "kernel-ready" in item.get("output", "")
                for item in self.provider.requests[-1]["request"]["input"]
            )
        )
        self.assertEqual(self.turn(session, "still alive"), "still alive")
        users = [
            part["text"]
            for entry in app.history(session)["items"]
            if entry["kind"] == "user"
            for part in entry["content"]
            if part["kind"] == "text"
        ]
        self.assertEqual(
            users,
            [
                "first prompt",
                "after restart",
                "ordinary turn",
                "lose kernel",
                "recover kernel",
                "still alive",
            ],
        )
        with app.api("/sessions") as response:
            info = next(
                item for item in json.load(response)["items"] if item["id"] == session
            )
        self.assertEqual(info["name"], "still alive")
