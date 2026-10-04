"""Unread background job results wake idle sessions once, even across idle reaping."""

import json
import os
import time
import unittest
import urllib.error

from harness import Albedo, Provider, exclusive, python, release_fifo, text

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

        wait_for(lambda: release_fifo(gate))
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
        # The transcript shows the one-line display; the model's notice with the
        # handle and advice stays in the request above.
        shown = "".join(
            part["text"] for part in notices[0]["content"] if part["kind"] == "text"
        )
        self.assertTrue(shown.startswith("job finished (exit_code=0"), shown)
        self.assertNotIn("\n", shown)
        self.assertNotIn("jobs[", shown)
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
        self.assertEqual(durable[0]["input_id"], notices[0]["input_id"])
        for entry in [notices[0], durable[0]]:
            self.assertEqual(
                [
                    part["value"]
                    for part in entry["content"]
                    if part["kind"] == "json" and part["field"] == "origin"
                ],
                ["job"],
            )
        time.sleep(2.5)
        self.assertEqual(len(self.users()), 3)

    def start_blocked_job(self):
        session = self.app.session()
        self.job_gate = self.app.workspace / "job-release"
        os.mkfifo(self.job_gate)
        self.app.prompt(session, "start a slow job").close()
        self.app.idle(session)
        self.assertEqual(len(self.users()), 2)
        return session

    def jobs_resource(self, session):
        return json.loads(
            self.app.api(f"/extensions/run/sessions/{session}/jobs").read()
        )

    def test_running_job_observation_and_page_clear_after_completion(self):
        session = self.start_blocked_job()
        kernel = json.loads(self.app.api(f"/sessions/{session}?tail=0").read())[
            "kernel"
        ]
        self.assertEqual(kernel["live_job_count"], 1)
        running = kernel["running_jobs"]
        self.assertEqual(len(running), 1)
        self.assertIsInstance(running[0]["pid"], int)
        self.assertIn(str(self.job_gate), running[0]["command"])
        # The row says when the owner recorded the job, in wall-clock
        # milliseconds, so a client can tell fresh work from settled work.
        started = running[0]["started_at"]
        self.assertIsInstance(started, int)
        self.assertGreater(started, 0)
        self.assertLess(abs(started - time.time() * 1000), 60_000)

        resource = self.jobs_resource(session)
        self.assertEqual(resource["items"], running)
        self.assertEqual(resource["live_job_count"], 1)
        page = resource["page"]
        self.assertEqual(page["title"], "jobs")
        self.assertEqual(page["summary"], "1 background job running")
        self.assertEqual(len(page["rows"]), 1)
        self.assertIn(str(self.job_gate), page["rows"][0]["text"])
        # A row resource is a validated representation or nothing; clients
        # reject one without an etag.
        row_resource = page["rows"][0]["resource"]
        self.assertTrue(
            row_resource is None or isinstance(row_resource.get("etag"), str),
            row_resource,
        )
        stop = page["actions"][0]["operation"]
        self.assertEqual(stop["method"], "POST")
        self.assertEqual(
            stop["path_template"],
            "/extensions/run/sessions/{session_id}/jobs/{job_id}/stop",
        )
        self.assertEqual(
            stop["path"],
            {
                "session_id": {"source": "literal", "value": session},
                "job_id": {"source": "row", "pointer": "/id"},
            },
        )

        gate = self.job_gate
        assert gate is not None

        wait_for(lambda: release_fifo(gate))
        wait_for(lambda: len(self.users()) >= 3)
        self.app.idle(session)
        after = json.loads(self.app.api(f"/sessions/{session}?tail=0").read())["kernel"]
        self.assertEqual(after["live_job_count"], 0)
        self.assertEqual(after["running_jobs"], [])
        self.assertEqual(self.jobs_resource(session)["items"], [])

    def test_stopping_one_job_and_rejecting_unknown_job(self):
        session = self.start_blocked_job()
        resource = self.jobs_resource(session)
        job_id = resource["items"][0]["id"]
        stopped = json.loads(
            self.app.api(
                f"/extensions/run/sessions/{session}/jobs/{job_id}/stop",
                method="POST",
            ).read()
        )
        self.assertEqual(stopped, {"stopped": job_id})
        wait_for(lambda: self.jobs_resource(session)["live_job_count"] == 0)
        self.assertEqual(self.jobs_resource(session)["items"], [])
        with self.assertRaises(urllib.error.HTTPError) as missing:
            self.app.api(
                f"/extensions/run/sessions/{session}/jobs/missing/stop",
                method="POST",
            )
        self.assertEqual(missing.exception.code, 404)


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
