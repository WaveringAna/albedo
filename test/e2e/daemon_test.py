"""Transcript paging and what the transcript keeps, through the real daemon."""

from dataclasses import dataclass
import http.client
import http.server
from collections.abc import Callable
import json
import resource
import socket
import threading
import time
import unittest
import urllib.error
import urllib.parse

from harness import Albedo, Provider, Reply, exclusive, operation_id, python, text

# More client connections than a macOS shell's default open-file limit.
CONNECTIONS = 300


@dataclass
class HeldCatalog:
    url: str
    release: Callable[[], None]


def held_catalog():
    """A local models catalog whose every request waits until it is released."""
    released = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, format, *args):
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


def read_response_details(connection):
    """Read one known-length HTTP response from a raw socket."""
    head = b""
    while b"\r\n\r\n" not in head:
        chunk = connection.recv(65536)
        if not chunk:
            raise AssertionError("connection closed before a response")
        head += chunk
    lines = head.split(b"\r\n\r\n", 1)
    body = lines[1] if len(lines) > 1 else b""
    length = 0
    headers = {}
    for line in lines[0].split(b"\r\n")[1:]:
        name, _, value = line.partition(b":")
        name = name.strip().lower()
        headers[name.decode()] = value.strip().decode()
        if name == b"content-length":
            length = int(value.strip())
    while len(body) < length:
        chunk = connection.recv(65536)
        if not chunk:
            raise AssertionError("connection closed mid-body")
        body += chunk
    return int(lines[0].split(b" ")[1]), headers, body


def read_response(connection):
    return read_response_details(connection)[0]


def refused_request(app, path, headers, *, method="PUT"):
    """Send only headers and require a refusal and closure within two seconds."""
    address = urllib.parse.urlsplit(app.base)
    head = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Host: {address.netloc}\r\n"
        + "".join(f"{name}: {value}\r\n" for name, value in headers.items())
        + "\r\n"
    ).encode()
    with socket.create_connection(
        (address.hostname, address.port), timeout=2
    ) as connection:
        connection.sendall(head)
        result = read_response_details(connection)
        try:
            closed = connection.recv(1) == b""
        except ConnectionResetError:
            closed = True
        if not closed:
            raise AssertionError("refusal left the connection open")
        return result


def delayed_request(app, method, path, body, headers):
    """Split the headers and delay the body, then reuse the connection."""
    address = urllib.parse.urlsplit(app.base)
    token = app.connection["token"]
    head = (
        f"{method} {path} HTTP/1.1\r\n"
        f"Host: {address.netloc}\r\n"
        + "".join(f"{name}: {value}\r\n" for name, value in headers.items())
        + f"Content-Type: application/json\r\n"
        f"Content-Length: {len(body)}\r\n\r\n"
    ).encode()
    connection = socket.create_connection((address.hostname, address.port), timeout=20)
    try:
        connection.sendall(head[:17])
        time.sleep(0.01)
        connection.sendall(head[17:])
        time.sleep(0.05)
        connection.sendall(body)
        first = read_response(connection)
        connection.sendall(
            (
                f"GET /server HTTP/1.1\r\n"
                f"Host: {address.netloc}\r\n"
                f"Authorization: Bearer {token}\r\n\r\n"
            ).encode()
        )
        return first, read_response(connection)
    finally:
        connection.close()


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
            next_page = None
            while True:
                query = {"limit": 2}
                if next_page is not None:
                    query["next"] = next_page
                with app.api(
                    f"/sessions/{session}/history?" + urllib.parse.urlencode(query)
                ) as response:
                    page = json.load(response)
                pages.append(page)
                if page["older"] is None:
                    break
                self.assertIsInstance(page["older"], str)
                self.assertNotEqual(page["older"], next_page)
                next_page = page["older"]
            prompts = [
                [
                    part["text"]
                    for entry in page["items"]
                    if entry["kind"] == "user"
                    for part in entry["content"]
                    if part["kind"] == "text"
                ]
                for page in pages
            ]
            self.assertEqual(
                [turn for turn in prompts if turn],
                [["newest prompt"], ["middle prompt"], ["oldest prompt"]],
            )
            self.assertIsNone(pages[-1]["older"])

    # exclusive: restarts the daemon
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

    # exclusive: shuts down and restarts the daemon
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
            paths = [
                ("GET", "/sessions", None),
                ("GET", "/providers/fixture/models", None),
            ]
            for session in sessions:
                paths += [
                    ("GET", f"/sessions/{session}?tail=0", None),
                    ("GET", f"/sessions/{session}/history?view=checkpoints", None),
                    ("GET", f"/sessions?parent_id={session}", None),
                    ("GET", f"/sessions/{session}?view=configuration", None),
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
                        except (http.client.HTTPException, OSError):
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
                with app.api("/server") as response:
                    instance_id = json.load(response)["instance_id"]
                app.api("/server/shutdown", {"instance_id": instance_id}).close()
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

    def test_a_late_request_body_keeps_the_keep_alive_connection(self):
        # mist parses every later TCP read as the next keep-alive request, so
        # a route that answers without reading its request body leaves those
        # bytes to that parser: a body arriving after its headers reads as a
        # new request, fails, and the connection closes without a response,
        # taking the client's next request with it. The router reads the body
        # up front, so a split write cannot cost the connection.
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            token = app.connection["token"]
            session = app.session()
            interrupt = f"/sessions/{session}/interrupt"

            # Every shape that answers without reading its body: a plain
            # route, an ignored POST body, an unknown route, and a route that
            # answers a session actor call.
            for method, path, body, status in (
                ("GET", "/server", b"{}", 200),
                ("GET", "/nope", b"{}", 404),
                ("PUT", f"/sessions/{session}/visits/{operation_id()}", b"{}", 200),
                ("POST", "/nope", b"{}", 404),
                ("POST", interrupt, b'{"run_id":null,"through_input_order":0}', 200),
            ):
                with self.subTest(f"{method} {path}"):
                    self.assertEqual(
                        delayed_request(
                            app,
                            method,
                            path,
                            body,
                            {"Authorization": "Bearer " + token},
                        ),
                        (status, 200),
                    )

    def test_empty_and_incomplete_bodies_are_handled_at_ingress(self):
        with Albedo() as app:
            token = {"Authorization": "Bearer " + app.connection["token"]}
            session = app.session()
            before = app.history(session)
            self.assertEqual(
                delayed_request(app, "GET", "/server", b"", token), (200, 200)
            )
            address = urllib.parse.urlsplit(app.base)
            with socket.create_connection(
                (address.hostname, address.port), timeout=2
            ) as connection:
                connection.sendall(
                    (
                        f"PUT /sessions/{session}/inputs/{operation_id()} HTTP/1.1\r\n"
                        f"Host: {address.netloc}\r\n"
                        f"Authorization: {token['Authorization']}\r\n"
                        "Content-Length: 2\r\n\r\n{"
                    ).encode()
                )
                connection.shutdown(socket.SHUT_WR)
                # Mist closes the socket when its body read encounters EOF.
                self.assertEqual(connection.recv(1), b"")
            self.assertEqual(app.history(session), before)

    def test_core_refuses_before_reading_withheld_bodies(self):
        provider = Provider(lambda _request: text("answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            token = {"Authorization": "Bearer " + app.connection["token"]}
            session = app.session()
            before = app.history(session)
            path = f"/sessions/{session}/inputs/{operation_id()}"
            for authorization in ({}, {"Authorization": "Bearer wrong"}):
                for length in ("2", "72200001", "invalid"):
                    with self.subTest(authorization=authorization, length=length):
                        status, headers, body = refused_request(
                            app, path, {**authorization, "Content-Length": length}
                        )
                        self.assertEqual(status, 401)
                        self.assertEqual(json.loads(body)["status"], 401)
                        self.assertEqual(headers["www-authenticate"].lower(), "bearer")
            for framing in (
                {"Content-Length": "72200001"},
                {"Content-Length": "invalid"},
                {"Transfer-Encoding": "chunked"},
            ):
                with self.subTest(origin_framing=framing):
                    status, _, _ = refused_request(
                        app,
                        path,
                        {**token, **framing, "Origin": "https://attacker.example"},
                    )
                    self.assertEqual(status, 403)
            self.assertEqual(app.history(session), before)
            self.assertFalse(provider.requests)

    def test_core_rejects_unsupported_and_oversized_body_framing(self):
        with Albedo() as app:
            session = app.session()
            before = app.history(session)
            token = {"Authorization": "Bearer " + app.connection["token"]}
            for framing, expected_status in (
                ({"Transfer-Encoding": "chunked", "Content-Length": "2"}, 400),
                ({"Transfer-Encoding": "identity", "Content-Length": "0"}, 400),
                ({"Content-Length": "-1"}, 400),
                ({"Content-Length": "+1"}, 400),
                ({"Content-Length": "1x"}, 400),
                ({"Content-Length": "72200001"}, 413),
            ):
                with self.subTest(framing=framing):
                    status, _, body = refused_request(
                        app,
                        f"/sessions/{session}/inputs/{operation_id()}",
                        {**token, **framing},
                    )
                    self.assertEqual(status, expected_status)
                    if framing.get("Transfer-Encoding") == "identity":
                        self.assertEqual(json.loads(body)["code"], "invalid_request")
            self.assertEqual(app.history(session), before)

            input_id = operation_id()
            resource = f"/sessions/{session}/inputs/{input_id}"
            payload = {"kind": "message", "text": "identity encoded input"}
            status, _, _ = refused_request(
                app,
                resource,
                {"Content-Encoding": "gzip", "Content-Length": "100"},
            )
            self.assertEqual(status, 401)
            with self.assertRaises(urllib.error.HTTPError) as caught:
                app.api(
                    resource,
                    payload,
                    method="PUT",
                    headers={"Content-Encoding": "gzip"},
                )
            self.assertEqual(caught.exception.code, 415)
            self.assertEqual(
                json.load(caught.exception)["code"], "unsupported_encoding"
            )
            self.assertEqual(app.history(session), before)
            with app.api(
                resource,
                payload,
                method="PUT",
                headers={"Content-Encoding": "identity"},
            ) as response:
                self.assertEqual(response.status, 202)
            app.idle(session)

    # exclusive: changes daemon startup open-file limits
    @exclusive
    def test_a_daemon_started_from_a_macos_shell_answers_hundreds_of_connections(self):
        # macOS starts a shell at a soft limit of 256 open files. The CLI, like
        # any Go program, lifts its own limit but starts children on the
        # original one, and a few hundred client connections would then run
        # the daemon out of files and take its listener down mid-accept.
        hard = resource.getrlimit(resource.RLIMIT_NOFILE)[1]

        def prepare(app):
            app.daemon.open_files = (256, hard)

        with Albedo(prepare=prepare) as app:
            headers = {"Authorization": "Bearer " + app.connection["token"]}
            connections = []
            for _ in range(CONNECTIONS):
                connection = http.client.HTTPConnection(
                    "127.0.0.1", app.connection["port"], timeout=20
                )
                connection.connect()
                self.addCleanup(connection.close)
                connections.append(connection)
            for connection in connections:
                connection.request("GET", "/server", headers=headers)
                response = connection.getresponse()
                response.read()
                self.assertEqual(response.status, 200)

    # exclusive: changes daemon open-file limits and crashes its listener
    @exclusive
    def test_a_listener_out_of_files_comes_back_on_the_daemons_port(self):
        # Accepts past the open-file limit crash glisten's acceptors until mist
        # restarts the whole listener, on the port it was built with. A port
        # the OS picks at each start would bring it back somewhere daemon.json
        # does not say, leaving a live daemon no client can reach.
        def prepare(app):
            app.daemon.open_files = (128, 128)

        with Albedo(prepare=prepare) as app:
            pid, port = app.connection["pid"], app.connection["port"]
            flood = []
            for _ in range(CONNECTIONS):
                try:
                    flood.append(
                        socket.create_connection(("127.0.0.1", port), timeout=20)
                    )
                except OSError:
                    pass
            # Nothing the daemon sends ends these sockets: each one ends when
            # the restarted listener's tree drops the connection it accepted,
            # or resets the one still waiting in its old socket's backlog.
            for connection in flood:
                try:
                    self.assertEqual(connection.recv(1), b"")
                except ConnectionResetError:
                    pass
                connection.close()

            record = json.loads((app.home / "daemon.json").read_text())
            self.assertEqual((record["pid"], record["port"]), (pid, port))
            deadline = time.monotonic() + 20
            while True:
                try:
                    with app.api("/server") as response:
                        self.assertEqual(response.status, 200)
                    break
                except OSError:
                    self.assertLess(
                        time.monotonic(), deadline, "the daemon's port stayed closed"
                    )
                    time.sleep(0.1)

    def test_a_thoughts_duration_is_kept_with_the_transcript(self):
        # summarized thinking streams once it is written: here the response
        # opens, thinks 0.6s, and its summary comes 0.3s before the answer,
        # so the thought is timed from the opening, not the summary
        def chunk(delta, finish=None):
            return {
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
            before = app.stream_page(session)
            app.prompt(session, "think first").close()
            app.idle(session)

            replay = app.stream_page(session, before)
            thoughts = [
                event["data"]
                for event in replay["events"]
                if event["type"] == "thinking"
            ]
            self.assertEqual(
                "".join(thought["text"] for thought in thoughts), "weighing it"
            )
            [published] = [
                event["data"]["entry"]
                for event in replay["events"]
                if event["type"] == "message"
                and event["data"]["entry"]["kind"] == "thinking"
            ]
            self.assertGreaterEqual(published["thinking_duration_ms"], 500)
            [durable] = [
                entry
                for entry in app.history(session)["items"]
                if entry["kind"] == "thinking"
            ]
            self.assertEqual(
                "".join(
                    part["text"]
                    for part in durable["content"]
                    if part["kind"] == "text"
                ),
                "weighing it",
            )
            self.assertGreaterEqual(durable["thinking_duration_ms"], 500)
            self.assertEqual(published["id"], durable["id"])

    def test_chunked_input_admission_counts_decoded_body_and_keeps_connection(self):
        provider = Provider(lambda _: text("chunked answer"))
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            session = app.session()
            input_id = operation_id()
            intent = {"kind": "message", "text": "chunked Café 😀"}
            payload = json.dumps(intent, ensure_ascii=False).encode()
            chunks = [payload[index : index + 3] for index in range(0, len(payload), 3)]
            connection = http.client.HTTPConnection(
                "127.0.0.1", app.connection["port"], timeout=20
            )
            self.addCleanup(connection.close)
            headers = {
                "Authorization": "Bearer " + app.connection["token"],
                "Content-Type": "application/json",
            }
            connection.request(
                "PUT",
                f"/sessions/{session}/inputs/{input_id}",
                chunks,
                headers,
                encode_chunked=True,
            )
            response = connection.getresponse()
            self.assertEqual(response.status, 202)
            self.assertEqual(json.load(response)["id"], input_id)
            connection.request("GET", "/server", headers=headers)
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.load(response)["state"], "ready")
            app.idle(session)
            users = [
                entry
                for entry in app.history(session)["items"]
                if entry["kind"] == "user"
            ]
            self.assertEqual([entry["input_id"] for entry in users], [input_id])
            self.assertEqual(
                [
                    part["text"]
                    for entry in users
                    for part in entry["content"]
                    if part["kind"] == "text"
                ],
                [intent["text"]],
            )
            self.assertEqual(len(provider.requests), 1)
