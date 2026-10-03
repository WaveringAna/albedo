"""A replay cursor cannot skip durable events from a replacement session actor."""

import json
import socket
import sqlite3
import subprocess
import unittest
import urllib.error

from harness import Albedo, Provider, ROOT, exclusive, text


def restart_actor(app, session):
    support = ROOT / "test/e2e/albedo_stream_replay_probe.erl"
    subprocess.run(
        ["erlc", "-Werror", "-o", str(app.root), str(support)],
        check=True,
        timeout=30,
    )
    cookie = (app.home / "inspect.cookie").read_text().strip()
    node = f"albedo_{app.daemon._pid}@{socket.gethostname().split('.')[0]}"
    beam = app.root / "albedo_stream_replay_probe.beam"
    expression = (
        f"Node = '{node}', "
        f"{{ok, Binary}} = file:read_file({json.dumps(str(beam))}), "
        "{module, albedo_stream_replay_probe} = "
        "rpc:call(Node, code, load_binary, "
        '[albedo_stream_replay_probe, "probe.erl", Binary]), '
        '<<"actor_stopped">> = rpc:call(Node, albedo_stream_replay_probe, '
        f"restart, [<<{json.dumps(session)}>>]), "
        'io:put_chars("actor_stopped"), halt().'
    )
    result = subprocess.run(
        [
            "erl",
            "+S",
            "2:2",
            "-sname",
            "stream_replay_probe",
            "-setcookie",
            cookie,
            "-noshell",
            "-eval",
            expression,
        ],
        capture_output=True,
        text=True,
        check=True,
        timeout=30,
    )
    if result.stdout != "actor_stopped":
        raise AssertionError(result.stdout + result.stderr)


class StreamReplayTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _: text("answer"))
        self.addCleanup(self.provider.close)

    def turn(self, app, session, prompt):
        app.prompt(session, prompt).close()
        app.idle(session)

    def assert_reset_history(self, page, prompts):
        self.assertEqual(page["events"][0]["type"], "reset")
        self.assertEqual(
            [
                part["text"]
                for entry in page["snapshot"]["history"]["items"]
                if entry["kind"] == "user"
                for part in entry["content"]
                if part["kind"] == "text"
            ],
            prompts,
        )

    # exclusive: enables daemon inspection at startup
    @exclusive
    def test_old_actor_cursor_inside_replacement_window_resets_durable_history(self):
        def prepare(app):
            app.daemon.env["ALBEDO_INSPECT"] = "1"

        with Albedo(self.provider, prepare=prepare) as app:
            session = app.session()
            self.turn(app, session, "before actor restart")
            old = app.stream_page(session)
            restart_actor(app, session)
            self.turn(app, session, "after actor restart")
            current = app.stream_page(session)
            replay = app.stream_page(session, old)
            self.assert_reset_history(
                replay, ["before actor restart", "after actor restart"]
            )
            self.assertNotEqual(replay["generation"], old["generation"])
            self.assertEqual(replay["generation"], current["generation"])

    # exclusive: restarts the daemon
    @exclusive
    def test_old_daemon_cursor_resets_durable_history(self):
        with Albedo(self.provider) as app:
            session = app.session()
            self.turn(app, session, "before daemon restart")
            old = app.stream_page(session)
            app.restart(crash=True)
            self.turn(app, session, "after daemon restart")
            current = app.stream_page(session)
            replay = app.stream_page(session, old)
            self.assert_reset_history(
                replay, ["before daemon restart", "after daemon restart"]
            )
            self.assertNotEqual(replay["generation"], old["generation"])
            self.assertEqual(replay["generation"], current["generation"])

    def test_same_generation_replays_only_subsequent_events_in_order(self):
        with Albedo(self.provider) as app:
            session = app.session()
            self.turn(app, session, "already consumed")
            old = app.stream_page(session)
            self.turn(app, session, "next prompt")
            self.turn(app, session, "last prompt")
            replay = app.stream_page(session, old)
            self.assertEqual(replay["generation"], old["generation"])
            self.assertGreater(replay["cursor"], old["cursor"])
            self.assertNotIn("reset", [event["type"] for event in replay["events"]])
            self.assertEqual(
                [
                    part["text"]
                    for event in replay["events"]
                    if event["type"] == "message"
                    and event["data"]["entry"]["kind"] == "user"
                    for part in event["data"]["entry"]["content"]
                    if part["kind"] == "text"
                ],
                ["next prompt", "last prompt"],
            )
            keepalive = app.stream_page(session, replay)
            self.assertEqual(keepalive["events"], [])
            self.assertEqual(keepalive["generation"], replay["generation"])
            self.assertEqual(keepalive["cursor"], replay["cursor"])

    # exclusive: renames the global transcript table
    @exclusive
    def test_failed_transcript_read_emits_failure_without_replacement_cursor(self):
        with Albedo(self.provider) as app:
            session = app.session()
            self.turn(app, session, "committed history")
            old = app.stream_page(session)
            other_generation = app.stream_page(app.session())["generation"]
            with sqlite3.connect(app.home / "albedo.sqlite") as database:
                database.execute(
                    "ALTER TABLE transcript RENAME TO unavailable_transcript"
                )
            with self.assertRaises(urllib.error.HTTPError) as caught:
                app.api(
                    f"/sessions/{session}?after_generation={other_generation}&after_seq={old['cursor']}&tail=2",
                    headers={"Accept": "text/event-stream"},
                )
            self.assertEqual(caught.exception.code, 503)
            problem = json.load(caught.exception)
            self.assertEqual(problem["code"], "request_unavailable")
            self.assertNotIn("snapshot", problem)
            self.assertNotIn("generation", problem)
            self.assertNotIn("cursor", problem)

    def test_evicted_cursor_resets_in_same_generation_and_initial_tail_pages_history(
        self,
    ):
        with Albedo(self.provider) as app:
            session = app.session()
            self.turn(app, session, "oldest prompt")
            old = app.stream_page(session)
            # A long streamed answer evicts the count-limited replay window.
            self.provider.script = lambda _: text("long answer " * 600)
            self.turn(app, session, "newest prompt")
            replay = app.stream_page(session, old)
            self.assertEqual(replay["generation"], old["generation"])
            self.assert_reset_history(replay, ["oldest prompt", "newest prompt"])
            initial = app.stream_page(session, tail=2)
            self.assert_reset_history(initial, ["newest prompt"])
            history = initial["snapshot"]["history"]
            self.assertIsNotNone(history["older"])
            with app.api(
                f"/sessions/{session}/history?limit=2&next={history['older']}"
            ) as response:
                older = json.load(response)
            self.assertEqual(
                [
                    part["text"]
                    for entry in older["items"]
                    if entry["kind"] == "user"
                    for part in entry["content"]
                    if part["kind"] == "text"
                ],
                ["oldest prompt"],
            )
