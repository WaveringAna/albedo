"""Daemon and Python crashes inject exactly one reset notice without corrupting history."""

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

    def test_daemon_restart_and_kernel_crash_emit_one_shot_reset_notices(self):
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
        self.assertEqual(rejected.exception.code, 409)
        self.assertEqual(self.turn(session, "after reset"), "after reset" + NOTICE)
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
            event["text"]
            for event in app.events(session)
            if event.get("type") == "user"
        ]
        self.assertEqual(
            users,
            [
                "first prompt",
                "after reset",
                "ordinary turn",
                "lose kernel",
                "recover kernel",
                "still alive",
            ],
        )
        with app.api("/sessions") as response:
            info = next(item for item in json.load(response) if item["id"] == session)
        self.assertEqual(info["title"], "still alive")


if __name__ == "__main__":
    unittest.main()
