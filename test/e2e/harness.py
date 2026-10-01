"""Shared fixtures for offline end-to-end tests, run through ``run.py``.

A provider is a scripted model: its callback receives each decoded request and
returns ``text(...)``, ``python(...)``, ``error(...)``, or a custom ``Reply``.
Both OpenAI streaming protocols are served. ``Provider(catalog=...)`` also serves
a local models catalog. ``Albedo`` gives each fixture a separate workspace and
provider route on one shared HTTP server, on the daemon the runner gave its
test. Tests share one daemon and keep to their own profile; an ``@exclusive``
test, which may change global settings or restart the daemon, gets a fresh one
that boots after its fixture's ``prepare(app)`` and is discarded afterwards, so
it never restores what it changed. ``providers={}`` leaves it unconfigured.
Setting ``app.daemon.open_files = (soft, hard)`` in ``prepare`` boots that
daemon under an open-file limit.
``write_extensions(settings)`` replaces extensions.json without letting the
daemon reach the network, and ``store_secrets(section, value)`` writes a
creds.json section such as the OAuth ``accounts`` or ``mcp`` server secrets.
A response ``Reply(..., usage=None)`` omits provider usage.

Example::

    from harness import Albedo, Provider, text

    provider = Provider(lambda request: text("hello"))
    try:
        with Albedo(provider) as app:
            session = app.session()
            app.prompt(session, "say hello").close()
            app.idle(session)
            assert provider.requests
    finally:
        provider.close()
"""

from __future__ import annotations

from typing import Any

import atexit
import contextlib
from dataclasses import dataclass, field
import http.client
import http.server
import io
import itertools
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "test"))
import scratch  # noqa: E402

scratch.claim("e2e")
# A test daemon needs two schedulers, and busy-waiting ones make every boot
# pin all cores of the machine.
TEST_VM_FLAGS = "+S 2:2 +SDcpu 2:2 +sbwt none +sbwtdcpu none +sbwtdio none"
# Credentials a provider reads from the environment. The daemon must not see
# the developer's, or a catalog reload reaches the live provider.
PROVIDER_ENVIRONMENT = ("ALIBABA_API_KEY", "DASHSCOPE_API_KEY", "ALIBABA_BASE_URL")
# Extension settings that keep a daemon off the network: the models catalog
# never refreshes by itself and the cache-TTL table fetches no remote copy.
OFFLINE = {"models": {"refreshHours": 0}, "cacheTtl": {"url": None}}


@dataclass
class Reply:
    """A scripted assistant response and optional transport behavior."""

    kind: str
    value: str = ""
    status: int = 200
    reasoning: str | None = None
    usage: dict | None = field(
        default_factory=lambda: {"input_tokens": 10, "output_tokens": 20}
    )
    delay: float = 0
    hang: bool = False
    tool_name: str = "python"
    tool_arguments: dict | None = None
    events: list[dict] | None = None


def text(
    value: str,
    *,
    reasoning: str | None = None,
    usage: dict | None = None,
    delay: float = 0,
    hang: bool = False,
) -> Reply:
    return Reply(
        "text",
        value,
        reasoning=reasoning,
        usage=usage or {"input_tokens": 10, "output_tokens": 20},
        delay=delay,
        hang=hang,
    )


def python(
    code: str, *, reasoning: str | None = None, tool_name: str = "python"
) -> Reply:
    return Reply("python", code, reasoning=reasoning, tool_name=tool_name)


def error(status: int, body: str = "fixture error") -> Reply:
    return Reply("error", body, status=status)


def _content_text(item):
    content = item.get("content", "")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            part.get("text", "") for part in content if isinstance(part, dict)
        )
    return ""


# Guards the provider registry and the shared provider server.
_config_lock = threading.RLock()


def exclusive(target):
    """Run the test, or every test of the class, on a daemon of its own that
    boots after the fixture's prepare step and is discarded afterwards: it may
    change global settings or restart the daemon."""
    target._e2e_exclusive = True
    return target


_providers = {}
_provider_ids = itertools.count(1)
_server = None


def _provider_server():
    global _server
    if _server is None:

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, format, *args):
                pass

            def do_GET(self):
                self.provider()._get(self)

            def do_POST(self):
                self.provider()._post(self)

            def provider(self):
                return _providers[self.path.split("/", 3)[2]]

        _server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        _server.daemon_threads = True
        threading.Thread(target=_server.serve_forever, daemon=True).start()
    return _server


class Provider:
    """Threaded fake provider that records requests and emits protocol SSE."""

    def __init__(self, script, *, chunk_size: int = 20, catalog=None):
        self.catalog = catalog
        self.script = script
        self.chunk_size = chunk_size
        self.requests: list[dict] = []
        self._lock = threading.Lock()
        self.route = str(next(_provider_ids))
        with _config_lock:
            _providers[self.route] = self
            self.server = _provider_server()
        self.url = f"http://127.0.0.1:{self.server.server_port}/t/{self.route}"

    def _get(owner, self):
        payload = json.dumps(owner.catalog).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(payload)

    def _post(owner, self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        record = {
            "path": self.path,
            "authorization": self.headers.get("Authorization"),
            "model": request.get("model"),
            "request": request,
        }
        with owner._lock:
            owner.requests.append(record)
            index = len(owner.requests) - 1
        reply = owner.script(request)
        if isinstance(reply, (list, tuple)):
            reply = reply[min(index, len(reply) - 1)]
        if reply.kind == "error":
            payload = json.dumps({"error": {"message": reply.value}}).encode()
            self.send_response(reply.status)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()

        def emit(value):
            if reply.delay:
                time.sleep(reply.delay)
            self.wfile.write(("data: " + json.dumps(value) + "\n\n").encode())
            self.wfile.flush()

        try:
            if reply.hang:
                time.sleep(60)
                return
            if reply.events is not None:
                for event in reply.events:
                    emit(event)
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                return
            chat = self.path.endswith("chat/completions")
            call_id = f"fixture-call-{index + 1}"
            arguments = json.dumps(
                reply.tool_arguments
                if reply.tool_arguments is not None
                else {"pattern": reply.value}
                if reply.tool_name == "lcm_grep"
                else {"code": reply.value, "timeout_ms": 60000}
            )
            if chat:
                if reply.reasoning:
                    emit(
                        {
                            "id": "fixture",
                            "choices": [
                                {
                                    "index": 0,
                                    "delta": {"reasoning_content": reply.reasoning},
                                    "finish_reason": None,
                                }
                            ],
                        }
                    )
                if reply.kind == "python":
                    for offset in range(0, len(arguments), owner.chunk_size):
                        tool_call: dict[str, object] = {
                            "index": 0,
                            "function": {
                                "arguments": arguments[
                                    offset : offset + owner.chunk_size
                                ]
                            },
                        }
                        if offset == 0:
                            tool_call.update(
                                {
                                    "id": call_id,
                                    "type": "function",
                                    "function": {
                                        "name": reply.tool_name,
                                        "arguments": arguments[: owner.chunk_size],
                                    },
                                }
                            )
                        delta = {"tool_calls": [tool_call]}
                        emit(
                            {
                                "id": "fixture",
                                "choices": [
                                    {"index": 0, "delta": delta, "finish_reason": None}
                                ],
                            }
                        )
                    emit(
                        {
                            "id": "fixture",
                            "choices": [
                                {"index": 0, "delta": {}, "finish_reason": "tool_calls"}
                            ],
                        }
                    )
                else:
                    for offset in range(0, len(reply.value), owner.chunk_size):
                        emit(
                            {
                                "id": "fixture",
                                "choices": [
                                    {
                                        "index": 0,
                                        "delta": {
                                            "content": reply.value[
                                                offset : offset + owner.chunk_size
                                            ]
                                        },
                                        "finish_reason": None,
                                    }
                                ],
                            }
                        )
                    emit(
                        {
                            "id": "fixture",
                            "choices": [
                                {"index": 0, "delta": {}, "finish_reason": "stop"}
                            ],
                        }
                    )
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
            else:
                emit({"type": "response.created", "response": {"id": "fixture"}})
                output = []
                if reply.reasoning:
                    emit(
                        {
                            "type": "response.reasoning_summary_text.delta",
                            "output_index": 0,
                            "summary_index": 0,
                            "delta": reply.reasoning,
                        }
                    )
                    output.append(
                        {
                            "id": "reasoning",
                            "type": "reasoning",
                            "summary": [
                                {"type": "summary_text", "text": reply.reasoning}
                            ],
                        }
                    )
                if reply.kind == "python":
                    for offset in range(0, len(arguments), owner.chunk_size):
                        emit(
                            {
                                "type": "response.function_call_arguments.delta",
                                "output_index": 0,
                                "delta": arguments[offset : offset + owner.chunk_size],
                            }
                        )
                    output.append(
                        {
                            "id": "call",
                            "type": "function_call",
                            "call_id": call_id,
                            "name": reply.tool_name,
                            "arguments": arguments,
                            "status": "completed",
                        }
                    )
                else:
                    for offset in range(0, len(reply.value), owner.chunk_size):
                        emit(
                            {
                                "type": "response.output_text.delta",
                                "output_index": 0,
                                "content_index": 0,
                                "delta": reply.value[
                                    offset : offset + owner.chunk_size
                                ],
                            }
                        )
                    output.append(
                        {
                            "id": "message",
                            "type": "message",
                            "role": "assistant",
                            "status": "completed",
                            "content": [
                                {
                                    "type": "output_text",
                                    "text": reply.value,
                                    "annotations": [],
                                }
                            ],
                        }
                    )
                completed = {"id": "fixture", "status": "completed", "output": output}
                if reply.usage is not None:
                    completed["usage"] = reply.usage
                emit({"type": "response.completed", "response": completed})
        except (BrokenPipeError, ConnectionResetError):
            pass

    def close(self):
        # Sessions can finish background turns after their test returns. Keep
        # their route alive until the shared daemon has stopped.
        pass


_daemons: list[Daemon] = []
# The launcher of this run's daemon build; see snapshot_daemon().
_executable = None
_daemons_lock = threading.RLock()
_discarding: list[threading.Thread] = []
_current = threading.local()
daemon_boots = 0
restart_seconds = 0.0
# mist closes a keep-alive connection after 10 idle seconds; one idle for less
# than this is reused, so a request never races the daemon closing it.
KEEP_ALIVE_SECONDS = 5


class _Connection(http.client.HTTPConnection):
    """A daemon connection that notes when it can carry the next request."""

    def __init__(self, port, token):
        super().__init__("127.0.0.1", port, timeout=20)
        self.token = token
        self.response_class = _Response
        self.used_at = time.monotonic()
        self.reusable = True
        self.response = None

    def idle(self):
        """Whether the next request may go out on this connection: its last
        response is done with and the daemon has not dropped it yet."""
        return (
            self.sock is not None
            and self.reusable
            and (self.response is None or self.response.isclosed())
            and time.monotonic() - self.used_at < KEEP_ALIVE_SECONDS
        )


class _Response(http.client.HTTPResponse):
    """Closing drains a short unread body so the connection can be reused;
    an event stream or a long body gives the connection up instead."""

    connection = None

    def close(self):
        connection = self.connection
        if connection is not None and not self.isclosed():
            streaming = self.getheader("content-type", "").startswith(
                "text/event-stream"
            )
            if streaming or self.length is None or self.length > 1 << 20:
                connection.reusable = False
            else:
                try:
                    self.read()
                except (OSError, http.client.HTTPException):
                    connection.reusable = False
        super().close()
        if connection is not None:
            connection.used_at = time.monotonic()
            if self.will_close or not connection.reusable:
                connection.close()


class Daemon:
    """One daemon and its hermetic home. A concurrent daemon is shared by
    tests that each keep to their own provider profile; any other serves one
    test, which may change its global state or restart it."""

    def __init__(self, name, *, concurrent=False):
        if not hasattr(sys.modules["__main__"], "__file__"):
            # A daemon lives until the process that booted it exits, which a
            # long-lived interpreter or agent kernel never does.
            raise RuntimeError(
                "run E2E tests through test/e2e/run.py, not an interactive interpreter"
            )
        self.concurrent = concurrent
        self.lock = threading.RLock()
        self.root = Path(tempfile.mkdtemp(prefix=f"{name}-"))
        self.home = self.root / "home"
        self.home.mkdir()
        (self.root / "user-home").mkdir()
        # Nothing of the developer's albedo setup reaches the daemon.
        self.env = dict(
            {
                key: value
                for key, value in os.environ.items()
                if key not in PROVIDER_ENVIRONMENT
                and key not in ("HOME", "ERL_FLAGS")
                and not key.startswith("ALBEDO_")
            },
            HOME=str(self.root / "user-home"),
            ALBEDO_HOME=str(self.home),
            ALBEDO_ROOT=str(ROOT),
            ALBEDO_NO_BROWSER="1",
            ALBEDO_PARENT_PID=str(os.getpid()),
            ERL_FLAGS=TEST_VM_FLAGS,
            ALBEDO_IDLE_SECONDS="10",
            ALBEDO_MCP_SECRET="configured-secret",
            ALBEDO_MCP_CLOSED=str(self.root / "closed"),
            ALBEDO_MCP_AMBIENT="must-not-reach-the-server",
        )
        if _executable:
            self.env["ALBEDO_DAEMON"] = _executable
        # A (soft, hard) open-file limit the CLI, and so the daemon it boots,
        # starts under; None passes on the test process's own.
        self.open_files = None
        self.connection = None
        self.base = None
        self._pid = None
        self._local = threading.local()
        with _daemons_lock:
            _daemons.append(self)

    @property
    def booted(self):
        return self._pid is not None

    def boot(self):
        """Start the daemon; the first fixture boots it after its prepare."""
        extensions = self.home / "extensions.json"
        if not extensions.exists():
            extensions.write_text(json.dumps(OFFLINE))
        self.cli("sessions")
        self._refresh()

    def _refresh(self):
        global daemon_boots
        self.connection = json.loads((self.home / "daemon.json").read_text())
        self.base = f"http://127.0.0.1:{self.connection['port']}"
        if self.connection["pid"] != self._pid:
            # A new PID is valid only after the old daemon has exited.
            if self._pid is not None and _alive(self._pid):
                raise AssertionError(f"a second daemon started in {self.home}")
            self._pid = self.connection["pid"]
            with _daemons_lock:
                daemon_boots += 1

    def restart(self, *, crash=False, prepare=None):
        """Replace the daemon under the same home, preparing storage between."""
        global restart_seconds
        started = time.monotonic()
        if crash:
            assert self._pid is not None
            os.kill(self._pid, signal.SIGKILL)
        elif not self._stop(timeout=15):
            self._fail("daemon did not stop")
        if prepare is not None:
            prepare()
        self.cli("sessions")
        self._refresh()
        with _daemons_lock:
            restart_seconds += time.monotonic() - started

    def _stop(self, timeout):
        try:
            self.api("/shutdown", {}).close()
        except (OSError, http.client.HTTPException):
            pass
        deadline = time.monotonic() + timeout
        while _alive(self._pid):
            if time.monotonic() > deadline:
                return False
            time.sleep(0.05)
        return True

    def shutdown(self):
        """Stop the daemon, killing it if it will not stop, and drop the home."""
        with self.lock:
            if self.booted:
                # The daemon's own record may be stale after a crash restart.
                path = self.home / "daemon.json"
                if path.exists():
                    self.connection = json.loads(path.read_text())
                    self.base = f"http://127.0.0.1:{self.connection['port']}"
                    self._pid = self.connection["pid"]
                if not self._stop(timeout=10):
                    assert self._pid is not None
                    os.kill(self._pid, signal.SIGKILL)
                self._pid = None
            shutil.rmtree(self.root, ignore_errors=True)
        with _daemons_lock:
            if self in _daemons:
                _daemons.remove(self)

    def kill(self):
        """SIGKILL the daemon without waiting for its lock, even mid-stop."""
        pid = self._pid
        if pid is not None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def discard(self):
        """Shut the daemon down in the background; the test that used it is
        done, and nothing waits on its teardown until the run ends."""
        thread = threading.Thread(target=self.shutdown)
        thread.start()
        with _daemons_lock:
            _discarding.append(thread)

    def _fail(self, message):
        log = self.home / "daemon.log"
        raise AssertionError(message + ("\n" + log.read_text() if log.exists() else ""))

    def _connection(self):
        connection = getattr(self._local, "connection", None)
        assert self.connection is not None
        port, token = self.connection["port"], self.connection["token"]
        # A restarted daemon has a new token and may be back on the same port.
        if connection is None or connection.token != token or not connection.idle():
            if connection is not None:
                # A response still being read, such as an event stream, keeps
                # its socket; closing it gives the connection up.
                connection.reusable = False
                if connection.response is None or connection.response.isclosed():
                    connection.close()
            connection = self._local.connection = _Connection(port, token)
        return connection

    def api(self, path, body=None, *, method=None):
        """One daemon request over this thread's kept-alive connection. A
        socket per request, polled at test speed, leaves thousands of ports in
        TIME_WAIT; the host runs out and unrelated connections fail."""
        connection = self._connection()
        assert self.connection is not None
        connection.used_at = time.monotonic()
        payload = None if body is None else json.dumps(body).encode()
        try:
            connection.request(
                method or ("GET" if payload is None else "POST"),
                path,
                payload,
                {
                    "Authorization": "Bearer " + self.connection["token"],
                    "Content-Type": "application/json",
                },
            )
            response = connection.getresponse()
        except BaseException:
            connection.close()
            raise
        response.connection, connection.response = connection, response
        if response.status < 400:
            return response
        payload = response.read()
        response.close()
        raise urllib.error.HTTPError(
            self.base + path,
            response.status,
            response.reason + ": " + payload.decode(errors="replace"),
            response.headers,
            io.BytesIO(payload),
        )

    def cli(self, *args):
        command = [str(ROOT / "cli/bin/albedo"), *args]
        if self.open_files:
            command = [
                sys.executable,
                "-c",
                _WITH_OPEN_FILES,
                *map(str, self.open_files),
                *command,
            ]
        result = subprocess.run(
            command,
            cwd=ROOT,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=45,
        )
        if result.returncode:
            self._fail(result.stdout + result.stderr)
        return result.stdout

    def install_shared_features(self):
        """Enable the additive global gateways concurrent tests rely on, once,
        before they start: none of them may change global state itself."""
        with on_daemon(self):
            app = Albedo().__enter__()
        settings = json.loads((self.home / "extensions.json").read_text())
        settings.setdefault("enabled", {})["proxy"] = True
        (self.home / "extensions.json").write_text(json.dumps(settings))
        self.api(
            f"/sessions/{app.session()}/extensions",
            {"name": "webhooks", "scope": "global", "enabled": True},
        ).close()


# Runs a command under a (soft, hard) open-file limit, as a shell started with
# that `ulimit -n` would.
_WITH_OPEN_FILES = """import os, resource, sys
resource.setrlimit(resource.RLIMIT_NOFILE, (int(sys.argv[1]), int(sys.argv[2])))
os.execv(sys.argv[3], sys.argv[3:])"""


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def snapshot_daemon():
    """Compile the daemon once for the run and boot every test daemon from a
    copy, not through `gleam run` (see test/snapshot-daemon.sh). test.sh
    snapshots once for every suite and passes it as ALBEDO_TEST_DAEMON."""
    global _executable
    _executable = os.environ.get("ALBEDO_TEST_DAEMON")
    if _executable:
        return
    result = subprocess.run(
        [str(ROOT / "test/snapshot-daemon.sh"), tempfile.mkdtemp(prefix="daemon-")],
        text=True,
        capture_output=True,
    )
    if result.returncode:
        raise RuntimeError("building the daemon failed:\n" + result.stderr)
    _executable = result.stdout.strip()


def current_daemon():
    """The daemon the runner gave this thread."""
    daemon = getattr(_current, "daemon", None)
    if daemon is None:
        raise RuntimeError("run E2E tests through test/e2e/run.py")
    return daemon


@contextlib.contextmanager
def on_daemon(daemon):
    """Run fixtures created on this thread against daemon."""
    previous = getattr(_current, "daemon", None)
    _current.daemon = daemon
    try:
        yield daemon
    finally:
        _current.daemon = previous


def shutdown():
    """Stop every daemon, then the provider server."""
    global _server
    # The run is over and no test watches these daemons stop, so none is
    # drained: a graceful stop sits out OTP's one-second pause for buffered
    # output (user_sup:terminate/2), and the shared daemon's drain of every
    # session takes longer still. Their kernels exit with them.
    for daemon in list(_daemons):
        daemon.kill()
    for thread in list(_discarding):
        thread.join()
    _discarding.clear()
    for daemon in list(_daemons):
        daemon.shutdown()
    if _server is not None:
        _server.shutdown()
        _server.server_close()
        _server = None
    with _config_lock:
        _providers.clear()


atexit.register(shutdown)


def _write_config(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        json.dump(value, output)
        temporary = output.name
    os.replace(temporary, path)


class Albedo:
    """A test's workspace and provider profile on the daemon the runner gave it."""

    def __init__(
        self,
        provider: Provider | None = None,
        *,
        protocol="chat_completions",
        providers=None,
        prepare=None,
    ):
        self.provider = provider or Provider(lambda _request: text("ok"))
        self._owns_provider = provider is None
        self.protocol = protocol
        self.providers = providers
        self.prepare = prepare

    def __enter__(self):
        self.daemon = daemon = current_daemon()
        with daemon.lock:
            self.root, self.home, self.env = daemon.root, daemon.home, daemon.env
            self.workspace = Path(tempfile.mkdtemp(prefix="workspace-", dir=self.root))
            self._concurrent = daemon.concurrent
            if self.prepare:
                self.prepare(self)
            if not (self.home / "extensions.json").exists():
                self.write_extensions({})
            default_name = (
                f"fixture-{self.provider.route}" if self._concurrent else "fixture"
            )
            configured: dict[str, Any] = (
                self.providers
                if self.providers is not None
                else {
                    default_name: {
                        "baseUrl": self.provider.url,
                        "apiKey": "fixture-key",
                        "model": "fixture-model",
                        "protocol": self.protocol,
                    }
                }
            )
            self.profile = next(iter(configured), None)
            if configured:
                current: dict[str, Any] = (
                    json.loads((self.home / "config.json").read_text())
                    if self._concurrent and (self.home / "config.json").exists()
                    else {"providers": {}}
                )
                current["providers"].update(configured)
                current["active"] = (
                    current.get("active", self.profile)
                    if self._concurrent
                    else self.profile
                )
                _write_config(self.home / "config.json", current)
            elif not self._concurrent and (self.home / "config.json").exists():
                (self.home / "config.json").unlink()
            if not daemon.booted:
                daemon.boot()
            return self

    @property
    def connection(self):
        return self.daemon.connection

    @property
    def base(self):
        return self.daemon.base

    def restart(self, *, crash=False, prepare=None):
        """Restart the daemon; optionally prepare offline storage fixtures."""
        self.daemon.restart(
            crash=crash, prepare=None if prepare is None else lambda: prepare(self)
        )

    def _fail(self, message):
        self.daemon._fail(message)

    def api(self, path, body=None, *, method=None):
        return self.daemon.api(path, body, method=method)

    def cli(self, *args):
        return self.daemon.cli(*args)

    def write_extensions(self, settings):
        """Replace extensions.json, keeping the daemon offline in whatever
        catalog settings leave out."""
        merged = {
            name: {**OFFLINE.get(name, {}), **value}
            if name in OFFLINE and isinstance(value, dict)
            else value
            for name, value in {**OFFLINE, **settings}.items()
        }
        (self.home / "extensions.json").write_text(json.dumps(merged))

    def store_secrets(self, section, value):
        """Replaces one creds.json section, where the daemon keeps every secret."""
        path = self.home / "creds.json"
        creds = json.loads(path.read_text()) if path.exists() else {}
        creds[section] = value
        path.write_text(json.dumps(creds))
        path.chmod(0o600)

    def session(self, workspace=None):
        with self.daemon.lock:
            if self._concurrent:
                with self.api(
                    "/sessions",
                    {
                        "workspace": str(workspace or self.workspace),
                        "provider": self.profile,
                    },
                ) as response:
                    created = json.load(response)
                assert created["provider"] == self.profile, created
                return created["id"]
            return json.loads(self.cli("new", str(workspace or self.workspace)))[
                "session"
            ]

    def prompt(self, session_id, content):
        return self.api(f"/sessions/{session_id}/events", {"content": content})

    def idle(self, session_id, timeout=30):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.api(f"/sessions/{session_id}/status") as response:
                status = json.load(response)
            if not status["running"]:
                return status
            time.sleep(0.05)
        self._fail(f"session did not settle: {status}")

    def events(self, session_id):
        with self.api(f"/sessions/{session_id}/stream") as response:
            for line in response:
                if line.startswith(b"data: "):
                    return json.loads(line[6:])["events"]
        return []

    def history(self, session_id):
        with self.api(f"/sessions/{session_id}/history") as response:
            return json.load(response)

    def __exit__(self, *_exc):
        if self._owns_provider:
            self.provider.close()
