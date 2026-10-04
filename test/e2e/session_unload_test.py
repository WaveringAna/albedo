"""Quiet sessions unload, watched ones stay, and session reads reuse discovery."""

import http.client
import json
import time
import unittest

from harness import Albedo, Provider, exclusive, text

# Short enough that the test waits seconds, long enough to outlast a turn.
UNLOAD_SECONDS = 2


def loaded(app):
    with app.api("/sessions?scope=all") as response:
        return {
            row["id"]: row["cursor"] is not None for row in json.load(response)["items"]
        }


def wait_for(condition, message):
    deadline = time.monotonic() + UNLOAD_SECONDS * 5
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.1)
    raise AssertionError(message)


# exclusive: shortens the daemon's unload limit
@exclusive
class SessionUnloadTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _request: text("ok"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            prepare=lambda app: app.env.update(
                ALBEDO_UNLOAD_SECONDS=str(UNLOAD_SECONDS)
            ),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def turn(self, session, prompt):
        self.app.prompt(session, prompt).close()
        self.app.idle(session)

    def test_quiet_session_unloads_unless_watched(self):
        app = self.app
        quiet, watched = app.session(), app.session()
        self.turn(quiet, "hello")
        self.turn(watched, "hello")
        # A connection of its own, so the requests below never share it.
        stream = http.client.HTTPConnection("127.0.0.1", app.connection["port"])
        self.addCleanup(stream.close)
        stream.request(
            "GET",
            f"/sessions/{watched}",
            headers={
                "Authorization": "Bearer " + app.connection["token"],
                "Accept": "text/event-stream",
            },
        )
        stream.getresponse().readline()

        wait_for(lambda: not loaded(app)[quiet], "a quiet session stayed loaded")
        self.assertTrue(loaded(app)[watched], "a watched session was unloaded")

        # Reading stored history, as the session list's preview does, does
        # not load the session again.
        with app.api(f"/sessions/{quiet}/history?limit=16") as response:
            self.assertTrue(json.load(response)["items"])
        self.assertFalse(loaded(app)[quiet])

        requests = len(self.provider.requests)
        self.turn(quiet, "back again")
        self.assertEqual(len(self.provider.requests), requests + 1)

        stream.close()
        wait_for(lambda: not loaded(app)[watched], "a detached session stayed loaded")

    def test_session_reads_reuse_discovery_until_reload(self):
        app = self.app
        session = app.session()

        def skills():
            with app.api(f"/sessions/{session}?tail=0") as response:
                return json.load(response)["selection"]["effective"]["skills"]

        before = skills()
        late = app.workspace / ".agents/skills/late/SKILL.md"
        late.parent.mkdir(parents=True)
        late.write_text("---\nname: late\ndescription: added later\n---\nbody\n")
        self.assertEqual(skills(), before, "a session read walked skill files")
        with app.api(f"/sessions/{session}/reload", {"target": "session"}) as response:
            json.load(response)
        self.assertTrue(any("late" in key for key in skills()))
