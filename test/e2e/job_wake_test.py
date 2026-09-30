"""Unread background job results wake idle sessions once, even across idle reaping."""

import json
import time
import unittest

from harness import Albedo, Provider, exclusive, python, text

# A daemon under this limit sweeps every half second, so the detached job
# below outlives several sweeps.
IDLE_SECONDS = 2


def user_text(request):
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
        result = predicate()
        if result:
            return result
        time.sleep(0.1)
    raise AssertionError("background job did not wake session")


class JobWakeCase(unittest.TestCase):
    idle_seconds = None

    def setUp(self):
        def script(request):
            last = request["messages"][-1]
            user = user_text(request)
            if last.get("role") == "user" and "start a slow job" in user:
                seconds = IDLE_SECONDS * 2.5 if "detached" in user else 1.2
                code = (
                    "import sys\njob = run(sys.executable, '-c', "
                    f"\"import time; time.sleep({seconds}); print('wake-done')\")\njob.id"
                )
                return python(code)
            return text("finished")

        def prepare(app):
            if self.idle_seconds:
                app.env["ALBEDO_IDLE_SECONDS"] = str(self.idle_seconds)

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def users(self):
        return [user_text(record["request"]) for record in self.provider.requests]

    def stream(self, session, query):
        with self.app.api(f"/sessions/{session}/stream{query}") as response:
            for line in response:
                if line.startswith(b"data: "):
                    return json.loads(line[6:])
        self.fail("no stream snapshot")


class JobWakeTests(JobWakeCase):
    def test_unread_job_wakes_once_with_live_source_and_durable_turn(self):
        session = self.app.session()
        self.app.prompt(session, "start a slow job").close()
        self.app.idle(session)
        self.assertEqual(len(self.users()), 2)
        before = self.stream(session, "?after_seq=-1")
        wait_for(lambda: len(self.users()) >= 3)
        self.app.idle(session)
        self.assertEqual(len(self.users()), 3)
        wake = self.users()[2]
        self.assertIn("background job finished", wake)
        self.assertIn("jobs[", wake)
        self.assertIn("output.read", wake)
        live = self.stream(session, f"?after_seq={before['cursor']}")["events"]
        notices = [
            event
            for event in live
            if event.get("type") == "user" and "job finished" in event.get("text", "")
        ]
        self.assertEqual(len(notices), 1)
        self.assertEqual(notices[0]["source"], "job")
        self.assertEqual(notices[0]["clientId"], "job")
        self.assertIn("exit_code=0", notices[0]["text"])
        durable = [
            event
            for event in self.stream(session, "?after_seq=-1")["events"]
            if event.get("type") == "user" and "job finished" in event.get("text", "")
        ]
        self.assertEqual(len(durable), 1)
        time.sleep(2.5)
        self.assertEqual(len(self.users()), 3)


@exclusive
class IdleSweepTests(JobWakeCase):
    idle_seconds = IDLE_SECONDS

    def test_live_job_survives_idle_kernel_sweep(self):
        session = self.app.session()
        self.app.prompt(session, "start a slow job, detached").close()
        self.app.idle(session)
        self.assertEqual(len(self.users()), 2)
        # No daemon contact while detached: a live job must pin its kernel.
        wait_for(lambda: len(self.users()) >= 3)
        self.app.idle(session)
        self.assertEqual(len(self.users()), 3)
        self.assertIn("background job finished", self.users()[2])
