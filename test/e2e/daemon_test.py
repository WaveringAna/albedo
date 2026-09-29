"""Transcript paging and what the transcript keeps, through the real daemon."""

from dataclasses import dataclass
import http.client
import http.server
import json
import threading
import unittest
import urllib.parse

from harness import Albedo, Provider, Reply, exclusive, python, text


@dataclass
class HeldCatalog:
    url: str
    release: callable


def held_catalog():
    """A local models catalog whose every request waits until it is released."""
    released = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass

        def do_GET(self):
            released.wait()

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()

    def release():
        released.set()
        server.shutdown()
        server.server_close()

    return HeldCatalog(f"http://127.0.0.1:{server.server_port}/api.json", release)


class DaemonTest(unittest.TestCase):
    def test_history_pages_recover_older_turns_once(self):
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            for message in ("oldest prompt", "middle prompt", "newest prompt"):
                app.prompt(session, message).close()
                app.idle(session)

            pages = []
            before = None
            while True:
                suffix = "" if before is None else f"&before={before}"
                with app.api(f"/sessions/{session}/history?rows=2{suffix}") as response:
                    page = json.load(response)
                pages.append(page)
                if not page["more"]:
                    break
                self.assertIsInstance(page["before"], int)
                self.assertNotEqual(page["before"], before)
                before = page["before"]

            prompts = [
                [event["text"] for event in page["events"] if event["type"] == "user"]
                for page in pages
            ]
            self.assertEqual(
                [turn for turn in prompts if turn],
                [["newest prompt"], ["middle prompt"], ["oldest prompt"]],
            )
            self.assertFalse(pages[-1]["more"])

    @exclusive
    def test_a_clean_restart_leaves_no_registry_crash_loop(self):
        # Shutdown closes the store before the VM halts, and the supervisor
        # may restart the registry inside that window; its init used to panic
        # on the closed store ten times before the supervisor gave up. What
        # holds the VM open long enough to lose the race is a models catalog
        # fetch still in flight, so the restart runs against a local catalog
        # that never answers; the fixture config itself stays, so later
        # fixtures keep their provider.
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        catalog = held_catalog()
        self.addCleanup(catalog.release)
        with Albedo(provider) as app:
            settings = json.loads((app.home / "extensions.json").read_text())
            settings["models"] = {"url": catalog.url}
            (app.home / "extensions.json").write_text(json.dumps(settings))
            (app.home / "models.json").unlink(missing_ok=True)
            log = app.home / "daemon.log"
            before = log.stat().st_size if log.exists() else 0
            app.restart()
            app.restart()
            tail = log.read_text(errors="replace")[before:]
            for marker in ("Noproc", "reached_max_restart_intensity", "callee exited"):
                self.assertNotIn(marker, tail)

    @exclusive
    def test_requests_during_a_restart_are_answered_not_crashed(self):
        # Shutdown closes each session and then the store before the VM halts,
        # and requests keep arriving meanwhile: ones queued behind the drain
        # used to die with the registry ("callee exited"), and later ones
        # found no registry at all. Kernels make the drain take a while, a
        # held catalog fetch keeps the VM up past the store, and a second
        # shutdown must not start a second drain.
        def script(request):
            called = any(
                message.get("role") == "tool" for message in request["messages"]
            )
            return text("done") if called else python("x = 1")

        provider = Provider(script)
        self.addCleanup(provider.close)
        catalog = held_catalog()
        self.addCleanup(catalog.release)
        with Albedo(provider) as app:
            settings = json.loads((app.home / "extensions.json").read_text())
            settings["models"] = {"url": catalog.url}
            (app.home / "extensions.json").write_text(json.dumps(settings))
            (app.home / "models.json").unlink(missing_ok=True)
            sessions = [app.session() for _ in range(3)]
            for session in sessions:
                app.prompt(session, "keep a variable").close()
            for session in sessions:
                app.idle(session)
            log = app.home / "daemon.log"
            before = log.stat().st_size if log.exists() else 0

            stop = threading.Event()
            paths = [("GET", "/sessions", None), ("GET", "/models/fixture", None)]
            for session in sessions:
                paths += [
                    ("GET", f"/sessions/{session}/status", None),
                    ("GET", f"/sessions/{session}/tree", None),
                    ("GET", f"/sessions/{session}/children", None),
                    ("PATCH", f"/sessions/{session}", {"name": ""}),
                ]

            # One kept-alive connection per worker, reopened only when the
            # daemon drops it: a fresh socket per request exhausts the host's
            # ephemeral ports within seconds, which fails every other
            # connection on the machine, live sessions included.
            def hammer(base, token):
                address = urllib.parse.urlsplit(base)
                headers = {
                    "Authorization": "Bearer " + token,
                    "Content-Type": "application/json",
                }
                connection = None
                while not stop.is_set():
                    for method, path, body in paths:
                        try:
                            connection = connection or http.client.HTTPConnection(
                                address.hostname, address.port, timeout=20
                            )
                            payload = None if body is None else json.dumps(body)
                            connection.request(method, path, payload, headers)
                            connection.getresponse().read()
                        except http.client.HTTPException, OSError:
                            if connection:
                                connection.close()
                            connection = None
                            stop.wait(0.01)
                if connection:
                    connection.close()

            workers = [
                threading.Thread(
                    target=hammer, args=(app.base, app.connection["token"])
                )
                for _ in range(6)
            ]
            for worker in workers:
                worker.start()
            try:
                # restart() asks again while the first drain runs.
                app.api("/shutdown", {}).close()
                app.restart()
            finally:
                stop.set()
                for worker in workers:
                    worker.join()
            tail = log.read_text(errors="replace")[before:]
            for marker in (
                "Noproc",
                "callee exited",
                "Callee subject had no owner",
                "reached_max_restart_intensity",
            ):
                self.assertNotIn(marker, tail)

    def test_a_thoughts_duration_is_kept_with_the_transcript(self):
        # summarized thinking streams once it is written: here the response
        # opens, thinks 0.6s, and its summary comes 0.3s before the answer,
        # so the thought is timed from the opening, not the summary
        chunk = lambda delta, finish=None: {
            "id": "fixture",
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
        reply = Reply(
            "text",
            delay=0.3,
            events=[
                chunk({"role": "assistant"}),
                chunk({"reasoning_content": "weighing it"}),
                chunk({"content": "answer"}),
                chunk({}, "stop"),
            ],
        )
        provider = Provider(lambda _request: reply)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "think first").close()
            app.idle(session)

            for source, events in (
                ("stream", app.events(session)),
                ("history", app.history(session)["events"]),
            ):
                thoughts = [event for event in events if event["type"] == "thinking"]
                self.assertEqual(
                    [event["text"] for event in thoughts], ["weighing it"], source
                )
                self.assertGreaterEqual(thoughts[0].get("elapsedMs", 0), 500, source)


if __name__ == "__main__":
    unittest.main()
