"""Unread background job results wake idle sessions once, even across idle reaping."""

import errno
import os
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
        self.job_gate = None

        def script(request):
            last = request["messages"][-1]
            user = user_text(request)
            if last.get("role") == "user" and "start a slow job" in user:
                seconds = IDLE_SECONDS * 2.5 if "detached" in user else 1.2
                program = (
                    f"open({str(self.job_gate)!r}, 'rb').read(1); print('wake-done')"
                    if self.job_gate is not None
                    else f"import time; time.sleep({seconds}); print('wake-done')"
                )
                code = (
                    f"import sys\njob = run(sys.executable, '-c', {program!r})\njob.id"
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


class JobWakeTests(JobWakeCase):
    def test_unread_job_wakes_once_with_live_source_and_durable_turn(self):
        session = self.app.session()
        gate = self.app.workspace / "job-release"
        self.job_gate = gate
        os.mkfifo(gate)
        self.app.prompt(session, "start a slow job").close()
        self.app.idle(session)
        self.assertEqual(len(self.users()), 2)
        before = self.app.stream_page(session)

        def release_job():
            try:
                descriptor = os.open(gate, os.O_WRONLY | os.O_NONBLOCK)
            except OSError as error:
                if error.errno == errno.ENXIO:
                    return False
                raise
            try:
                os.write(descriptor, b"x")
            finally:
                os.close(descriptor)
            return True

        wait_for(release_job)
        wait_for(lambda: len(self.users()) >= 3)
        self.app.idle(session)
        self.assertEqual(len(self.users()), 3)
        wake = self.users()[2]
        self.assertIn("background job finished", wake)
        self.assertIn("jobs[", wake)
        self.assertIn("output.read", wake)
        live = self.app.stream_page(session, before)["events"]
        notices = [
            event["data"]["entry"]
            for event in live
            if event["type"] == "message"
            and event["data"]["entry"]["kind"] == "note"
            and any(
                part["kind"] == "text" and "job finished" in part["text"]
                for part in event["data"]["entry"]["content"]
            )
        ]
        self.assertEqual(
            len(notices),
            1,
            {"live": live, "history": self.app.history(session)},
        )
        self.assertIn(
            "exit_code=0",
            "".join(
                part["text"] for part in notices[0]["content"] if part["kind"] == "text"
            ),
        )
        durable = [
            entry
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "note"
            and any(
                part["kind"] == "text" and "job finished" in part["text"]
                for part in entry["content"]
            )
        ]
        self.assertEqual(len(durable), 1)
        self.assertEqual(durable[0]["id"], notices[0]["id"])
        self.assertEqual(durable[0]["turn_id"], notices[0]["turn_id"])
        self.assertIsNotNone(durable[0]["turn_id"])
        self.assertIsNone(durable[0]["input_id"])
        for entry in [notices[0], durable[0]]:
            self.assertEqual(
                [
                    part["value"]
                    for part in entry["content"]
                    if part["kind"] == "json" and part["field"] == "origin"
                ],
                ["note"],
            )
        time.sleep(2.5)
        self.assertEqual(len(self.users()), 3)


# exclusive: changes daemon idle sweep timing
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
