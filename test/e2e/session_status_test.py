"""The stream pushes the live facts a watching client used to poll for."""

import http.client
import json
import queue
import threading
import time
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, Provider, latest_user, python, text

# Long enough for the daemon's sidebar pace plus a loaded test host.
PUSH_SECONDS = 25


class Stream:
    """One session subscription, read in the background so a test can wait."""

    def __init__(self, app, session):
        self.connection = http.client.HTTPConnection(
            "127.0.0.1", app.connection["port"]
        )
        self.connection.request(
            "GET",
            f"/sessions/{session}?tail=0",
            headers={
                "Authorization": "Bearer " + app.connection["token"],
                "Accept": "text/event-stream",
            },
        )
        self.response = self.connection.getresponse()
        self.batches = queue.Queue()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()

    def _read(self):
        try:
            for line in self.response:
                if line.startswith(b"data: "):
                    self.batches.put(json.loads(line[6:]))
        except (OSError, ValueError, AttributeError):
            # The stream was closed under the reader at cleanup; http.client
            # reports that as a missing buffer rather than a socket error.
            return

    def batch(self, seconds=PUSH_SECONDS):
        try:
            return self.batches.get(timeout=seconds)
        except queue.Empty:
            raise AssertionError(f"no stream batch within {seconds}s") from None

    def pushed(self, matches, seconds=PUSH_SECONDS):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for event in self.batch(deadline - time.monotonic())["events"]:
                if matches(event):
                    return event
        raise AssertionError(f"no pushed event within {seconds}s")

    def close(self):
        self.connection.close()


class SessionStatusPushTests(unittest.TestCase):
    def setUp(self):
        def script(request):
            if request["messages"][-1].get("role") == "tool":
                return text("job started")
            if "start job" in latest_user(request):
                # A job that outlives the cell: the kernel reports it live, and
                # its end is the change a watching client must hear about.
                return python("handle = run('sleep', '4')\nprint(handle.id)")
            return text("done")

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)

    def subscribe(self, app, session):
        stream = Stream(app, session)
        self.addCleanup(stream.close)
        return stream

    def turn(self, app, session, prompt):
        app.prompt(session, prompt).close()
        app.idle(session)

    def activate_work_item(self, app, title):
        """An item the work sidebar lists: it shows only what is active."""
        workspace = urllib.parse.quote(str(app.workspace), safe="")
        with app.api(
            f"/extensions/work/items?workspace={workspace}", {"title": title}
        ) as created:
            resource = json.load(created)["resource"]
        self.assertEqual(resource["value"]["title"], title)
        with app.api(
            f"/extensions/work/items/{resource['value']['id']}?workspace={workspace}",
            {"status": "active"},
            method="PATCH",
            headers={"If-Match": resource["etag"]},
        ) as changed:
            self.assertEqual(
                json.load(changed)["resource"]["value"]["status"], "active"
            )

    def test_status_view_reads_the_live_facts_alone(self):
        with Albedo(self.provider) as app:
            session = app.session()
            with app.api(f"/sessions/{session}?view=status") as response:
                read = json.load(response)
            self.assertEqual(
                sorted(read), ["cursor", "glances", "id", "kernel", "status", "usage"]
            )
            self.assertEqual(read["id"], session)
            self.assertEqual(read["status"]["phase"], "idle")
            self.assertEqual(read["glances"], [])
            self.assertEqual(read["kernel"]["state"], "none")
            self.assertIsNone(read["usage"]["model"])
            # Replay and tail belong to the event stream, not the lean read.
            for query in ("tail=0", "after_generation=x&after_seq=0"):
                with self.assertRaises(urllib.error.HTTPError) as caught:
                    app.api(f"/sessions/{session}?view=status&{query}")
                self.assertEqual(caught.exception.code, 400)
                self.assertEqual(json.load(caught.exception)["code"], "invalid_request")

    def test_stream_pushes_a_job_starting_and_ending(self):
        with Albedo(self.provider) as app:
            session = app.session()
            stream = self.subscribe(app, session)
            # The initial batch is still a complete snapshot: a fresh client
            # never needs a read to fill its footer.
            first = stream.batch()
            self.assertEqual(first["snapshot"]["id"], session)
            self.assertIn("kernel", first["snapshot"])
            self.assertIn("glances", first["snapshot"])

            app.prompt(session, "start job").close()
            started = stream.pushed(
                lambda event: (
                    event["type"] == "kernel"
                    and (event["data"]["kernel"]["live_job_count"] or 0) >= 1
                )
            )
            self.assertEqual(started["data"]["kernel"]["state"], "attached")
            self.assertTrue(started["data"]["kernel"]["running_jobs"])

            app.idle(session)
            ended = stream.pushed(
                lambda event: (
                    event["type"] == "kernel"
                    and event["data"]["kernel"]["live_job_count"] == 0
                )
            )
            self.assertEqual(ended["data"]["kernel"]["running_jobs"], [])

    def test_stream_pushes_a_sidebar_change(self):
        with Albedo(self.provider) as app:
            session = app.session()
            self.turn(app, session, "hello")
            stream = self.subscribe(app, session)
            stream.batch()
            self.activate_work_item(app, "pushed glance")

            def shows_work(event):
                return event["type"] == "glances" and any(
                    row["text"] == "pushed glance"
                    for glance in event["data"]["glances"]
                    for row in glance["rows"]
                )

            event = stream.pushed(shows_work)
            glance = next(
                glance
                for glance in event["data"]["glances"]
                if glance["extension"] == "work"
            )
            self.assertEqual(glance["title"], "active work")


if __name__ == "__main__":
    unittest.main()
