"""Unread TCP streams cannot retain unbounded activity or block model completion."""

import json
import socket
import subprocess
import threading
import unittest

from harness import Albedo, Provider, ROOT, exclusive, text


class StreamProbe:
    def __init__(self, app):
        self.app = app
        source = ROOT / "test/e2e/albedo_stream_pressure_probe.erl"
        subprocess.run(
            ["erlc", "-Werror", "-o", str(app.root), str(source)],
            check=True,
            timeout=30,
        )

    def call(self, function, arguments="[]"):
        app = self.app
        cookie = (app.home / "inspect.cookie").read_text().strip()
        node = f"albedo_{app.daemon._pid}@{socket.gethostname().split('.')[0]}"
        beam = app.root / "albedo_stream_pressure_probe.beam"
        expression = (
            f"Node = '{node}', "
            f"{{ok, Binary}} = file:read_file({json.dumps(str(beam))}), "
            "{module, albedo_stream_pressure_probe} = "
            "rpc:call(Node, code, load_binary, "
            '[albedo_stream_pressure_probe, "probe.erl", Binary]), '
            f"io:put_chars(rpc:call(Node, albedo_stream_pressure_probe, {function}, {arguments})), halt()."
        )
        result = subprocess.run(
            [
                "erl",
                "+S",
                "2:2",
                "-sname",
                f"pressure_probe_{app.daemon._pid}",
                "-setcookie",
                cookie,
                "-noshell",
                "-eval",
                expression,
            ],
            capture_output=True,
            text=True,
            check=False,
            cwd=app.root,
            timeout=40,
        )
        if result.returncode != 0:
            raise AssertionError(result.stdout + result.stderr)
        return json.loads(result.stdout)


def unread_stream(app, path):
    connection = socket.socket()
    connection.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
    connection.settimeout(15)
    connection.connect(("127.0.0.1", app.connection["port"]))
    connection.sendall(
        (
            f"GET {path} HTTP/1.1\r\nHost: localhost:{app.connection['port']}\r\n"
            f"Authorization: Bearer {app.connection['token']}\r\n"
            "Accept: text/event-stream\r\n\r\n"
        ).encode()
    )
    # Read only the readiness batch, then leave all later socket data unread.
    initial = b""
    while b"data: " not in initial or b"\n\n" not in initial.split(b"data: ", 1)[1]:
        part = connection.recv(1)
        if not part:
            raise AssertionError("stream closed before readiness")
        initial += part
    return connection


# exclusive: enables daemon inspection at startup and measures global subscribers
@exclusive
class StreamPressureTest(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(lambda _: text("model completed under pressure"))
        self.addCleanup(self.provider.close)
        self.app = Albedo(
            self.provider,
            prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1"),
        )
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.probe = StreamProbe(self.app)

    def test_stalled_agents_feed_is_bounded_while_responsive_feed_and_model_complete(
        self,
    ):
        sessions = [self.app.session() for _ in range(8)]
        stalled = unread_stream(self.app, "/sessions?scope=all")
        self.addCleanup(stalled.close)
        observed = []
        ready = threading.Event()
        completed = threading.Event()

        def consume():
            with self.app.api(
                "/sessions?scope=all", headers={"Accept": "text/event-stream"}
            ) as response:
                for line in response:
                    if line.startswith(b"data: "):
                        events = json.loads(line[6:])["events"]
                        observed.extend(events)
                        ready.set()
                        if any(
                            event["type"] == "activity"
                            and any(
                                row["text"] == "model completed under pressure"
                                for row in event["data"]["activity"]["lines"]
                            )
                            for event in events
                        ):
                            completed.set()
                            return

        threading.Thread(target=consume, daemon=True).start()
        self.assertTrue(ready.wait(5), "responsive feed never subscribed")
        ids = "[" + ",".join(f"<<{json.dumps(session)}>>" for session in sessions) + "]"
        measured = self.probe.call("pressure_json", f"[{ids}]")
        self.assertTrue(measured["pressure"], measured)
        self.assertEqual(measured["blocked"], 1, measured)
        self.app.prompt(
            sessions[0], "complete while another subscriber is stalled"
        ).close()
        self.app.idle(sessions[0])
        self.assertTrue(completed.wait(5), "responsive feed lost model completion")
        self.assertLessEqual(measured["count"], 256, measured)
        self.assertLessEqual(measured["bytes"], 1048576, measured)
        self.assertLessEqual(measured["mailbox_bytes"], 1024, measured)
        self.assertLessEqual(measured["mailbox"], 3, measured)
        pressure_events = [
            event
            for event in observed
            if event["type"] == "activity"
            and event["data"]["activity"]["lines"]
            and event["data"]["activity"]["lines"][0]["text"].startswith("pressure:")
        ]
        self.assertEqual(len(pressure_events), measured["published"])
        for session in sessions:
            self.assertEqual(
                [
                    int(event["data"]["activity"]["lines"][0]["text"].split(":", 3)[2])
                    for event in pressure_events
                    if event["data"]["session_id"] == session
                ],
                list(range(1, measured["published"] // len(sessions) + 1)),
            )
        self.assertFalse(any(event["type"] == "overflow" for event in observed))
        with self.app.api(f"/sessions/{sessions[0]}?tail=0") as response:
            snapshot = json.load(response)
        self.assertEqual(snapshot["status"]["phase"], "idle")
        stalled.close()
        self.assertEqual(
            self.probe.call("removed_json"), {"subscribers": 0, "queues": 0}
        )

    def test_idle_agents_disconnect_removes_subscription_without_publication(self):
        connection = unread_stream(self.app, "/sessions?scope=all")
        self.assertEqual(self.probe.call("subscriptions_json")["subscribers"], 1)
        connection.close()
        self.assertEqual(
            self.probe.call("removed_json"), {"subscribers": 0, "queues": 0}
        )

    def test_agent_count_byte_and_oversize_limits_emit_only_overflow_then_close(self):
        session = self.app.session()
        for name, count, size in (
            ("count", 257, 16),
            ("bytes", 128, 16384),
            ("oversize", 1, 1048577),
        ):
            with (
                self.subTest(limit=name),
                self.app.api(
                    "/sessions?scope=all", headers={"Accept": "text/event-stream"}
                ) as response,
            ):
                initial = next(line for line in response if line.startswith(b"data: "))
                self.assertEqual(json.loads(initial[6:])["events"][0]["type"], "ready")
                measured = self.probe.call(
                    "burst_json", f"[[<<{json.dumps(session)}>>],{count},{size}]"
                )
                batches = [
                    json.loads(line[6:])
                    for line in response
                    if line.startswith(b"data: ")
                ]
                self.assertEqual(
                    batches, [{"events": [{"type": "overflow", "data": {}}]}]
                )
                self.assertEqual(measured["overflow"], 1, measured)
                self.assertLessEqual(measured["count"], 256, measured)
                self.assertLessEqual(measured["bytes"], 1048576, measured)
                if name == "count":
                    self.assertEqual(measured["count"], 256, measured)
                elif name == "bytes":
                    self.assertLess(measured["count"], 256, measured)
                else:
                    self.assertEqual(measured["bytes"], 0, measured)
            self.assertEqual(
                self.probe.call("removed_json"), {"subscribers": 0, "queues": 0}
            )
        self.app.prompt(session, "model continues after overflow").close()
        self.app.idle(session)
        with self.app.api(f"/sessions/{session}?tail=0") as response:
            snapshot = json.load(response)
        self.assertEqual(snapshot["status"]["phase"], "idle")

    def test_stalled_session_has_one_wake_and_reconnect_resets_durable_history(self):
        session = self.app.session()
        before = self.app.stream_page(session)
        connection = unread_stream(self.app, f"/sessions/{session}")
        self.addCleanup(connection.close)
        self.provider.chunk_size = 4096
        self.provider.script = lambda _: text("session pressure " * 250000, delay=0.002)
        self.app.prompt(session, "durable prompt under session pressure").close()
        measured = self.probe.call(
            "session_pressure_json", f"[<<{json.dumps(session)}>>]"
        )
        self.assertEqual(measured["blocked"], 1, measured)
        self.assertLessEqual(measured["wakes"], 1, measured)
        self.app.idle(session)
        recovered = self.app.stream_page(session, before, tail=2)
        self.assertEqual(recovered["generation"], before["generation"])
        self.assertEqual(recovered["events"][0]["type"], "reset")
        snapshot = recovered["snapshot"]
        self.assertIsNotNone(snapshot["history"]["older"])
        earliest = min(entry["position"] for entry in snapshot["history"]["items"])
        with self.app.api(
            f"/sessions/{session}/history?before={earliest}&limit=2"
        ) as response:
            earlier = json.load(response)
        self.assertIn(
            "durable prompt under session pressure",
            [
                part["text"]
                for entry in earlier["items"]
                if entry["kind"] == "user"
                for part in entry["content"]
                if part["kind"] == "text"
            ],
        )
        self.assertLessEqual(len(json.dumps(recovered).encode()), 1048576)

    def test_idle_session_disconnect_removes_watcher_without_publication(self):
        session = self.app.session()
        connection = unread_stream(self.app, f"/sessions/{session}")
        connection.close()
        measured = self.probe.call(
            "session_removed_json", f"[<<{json.dumps(session)}>>]"
        )
        self.assertEqual(measured["watchers"], 0, measured)
