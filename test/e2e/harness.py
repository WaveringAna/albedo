"""Shared fixtures for offline end-to-end tests.

A provider is a scripted model: its callback receives each decoded request and
returns ``text(...)``, ``python(...)``, ``error(...)``, or a custom ``Reply``.
Both OpenAI streaming protocols are served. ``Provider(catalog=...)`` also serves
a local models catalog. ``Albedo`` gives each fixture a separate workspace and
provider route on one shared HTTP server and one shared CLI daemon. Pass
``prepare(app)`` to write fixtures before use; only the first fixture can
prepare a pristine daemon home. ``providers={}`` leaves it unconfigured.
``store_secrets(section, value)`` writes a creds.json section such as the
OAuth ``accounts`` or ``mcp`` server secrets.
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

import atexit
from dataclasses import dataclass, field
import itertools
import signal
import http.server
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import urllib.error

ROOT = Path(__file__).resolve().parents[2]
# A test daemon needs two schedulers, and busy-waiting ones make every boot
# pin all cores of the machine.
TEST_VM_FLAGS = "+S 2:2 +SDcpu 2:2 +sbwt none +sbwtdcpu none +sbwtdio none"
# Credentials a provider reads from the environment. The daemon must not see
# the developer's, or a catalog reload reaches the live provider.
PROVIDER_ENVIRONMENT = ("ALIBABA_API_KEY", "DASHSCOPE_API_KEY", "ALIBABA_BASE_URL")


@dataclass
class Reply:
    """A scripted assistant response and optional transport behavior."""

    kind: str
    value: str = ""
    status: int = 200
    reasoning: str | None = None
    usage: dict = field(
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


# The concurrent phase uses distinct profiles and serializes every change to
# the process-wide daemon configuration. Exclusive tests retain fixture names.
_config_lock = threading.RLock()
_parallel = threading.local()


def exclusive(target):
    target._e2e_exclusive = True
    return target


_providers = {}
_provider_ids = itertools.count(1)
_server = None


def _provider_server():
    global _server
    if _server is None:

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
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
                        delta = {
                            "tool_calls": [
                                {
                                    "index": 0,
                                    "function": {
                                        "arguments": arguments[
                                            offset : offset + owner.chunk_size
                                        ]
                                    },
                                }
                            ]
                        }
                        if offset == 0:
                            delta["tool_calls"][0].update(
                                {
                                    "id": call_id,
                                    "type": "function",
                                    "function": {
                                        "name": reply.tool_name,
                                        "arguments": arguments[: owner.chunk_size],
                                    },
                                }
                            )
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


_shared = None
_daemon_pid = None
daemon_boots = 0
restart_seconds = 0.0
_suite_fixture = None


def shutdown():
    global _shared
    if _shared is None:
        return
    app = _shared
    # The first fixture's connection may be stale after a restart.
    path = app.home / "daemon.json"
    if path.exists():
        app.connection = json.loads(path.read_text())
        app.base = f"http://127.0.0.1:{app.connection['port']}"
        pid = app.connection["pid"]
        try:
            app.api("/shutdown", {}).close()
        except Exception:
            pass
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.05)
        else:
            os.kill(pid, signal.SIGKILL)
    if app.process.poll() is None:
        app.process.terminate()
        try:
            app.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            app.process.kill()
            app.process.wait()
    app.temp.cleanup()
    _shared = None
    if _server is not None:
        _server.shutdown()
        _server.server_close()
    with _config_lock:
        _providers.clear()


def enable_parallel_features():
    """Install additive global gateways once, before concurrent fixtures start."""
    global _suite_fixture
    if _suite_fixture is not None:
        return
    app = Albedo().__enter__()
    _suite_fixture = app
    settings = json.loads((app.home / "extensions.json").read_text())
    settings.setdefault("enabled", {})["proxy"] = True
    (app.home / "extensions.json").write_text(json.dumps(settings))
    session = app.session()
    app.api(
        f"/sessions/{session}/extensions",
        {"name": "webhooks", "scope": "global", "enabled": True},
    ).close()


atexit.register(shutdown)


def _write_config(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as output:
        json.dump(value, output)
        temporary = output.name
    os.replace(temporary, path)


class Albedo:
    """Per-test workspace and provider profile over one process-wide daemon."""

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
        with _config_lock:
            global _shared
            if _shared is None:
                if not hasattr(sys.modules["__main__"], "__file__"):
                    # A daemon lives until the process that booted it exits,
                    # which a long-lived interpreter or agent kernel never does.
                    raise RuntimeError(
                        "run E2E tests through test/e2e/run.py, not an interactive interpreter"
                    )
                self.temp = tempfile.TemporaryDirectory(prefix="albedo-e2e-")
                self.root = Path(self.temp.name)
                self.home = self.root / "home"
                self.home.mkdir()
                (self.root / "user-home").mkdir()
                self.env = dict(
                    {
                        name: value
                        for name, value in os.environ.items()
                        if name not in PROVIDER_ENVIRONMENT
                    },
                    HOME=str(self.root / "user-home"),
                    ALBEDO_HOME=str(self.home),
                    ALBEDO_PARENT_PID=str(os.getpid()),
                    ERL_FLAGS=TEST_VM_FLAGS,
                    ALBEDO_IDLE_SECONDS="10",
                    ALBEDO_MCP_SECRET="configured-secret",
                    ALBEDO_MCP_CLOSED=str(self.root / "closed"),
                    ALBEDO_MCP_AMBIENT="must-not-reach-the-server",
                )
                _shared = self
                first = True
            else:
                first = False
                shared = _shared
                self.temp, self.root, self.home, self.env = (
                    shared.temp,
                    shared.root,
                    shared.home,
                    shared.env,
                )
            self.workspace = Path(tempfile.mkdtemp(prefix="workspace-", dir=self.root))
            self._concurrent = getattr(_parallel, "enabled", False)
            self._saved = {
                name: (self.home / name).read_bytes()
                if (self.home / name).exists()
                else None
                for name in (
                    "config.json",
                    "extensions.json",
                    "creds.json",
                    "models.json",
                )
            }
            if self.prepare:
                self.prepare(self)
            if not (self.home / "extensions.json").exists():
                (self.home / "extensions.json").write_text(
                    json.dumps({"models": {"refreshHours": 0},
                                "cacheTtl": {"url": None}})
                )
            default_name = (
                f"fixture-{self.provider.route}" if self._concurrent else "fixture"
            )
            configured = (
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
                current = (
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
            if first:
                self.process = subprocess.Popen(
                    [str(ROOT / "cli/bin/albedo"), "sessions"],
                    cwd=ROOT,
                    env=self.env,
                    text=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                deadline = time.monotonic() + 30
                while (
                    not (self.home / "daemon.json").exists()
                    and time.monotonic() < deadline
                ):
                    if self.process.poll() is not None:
                        self._fail("daemon exited during startup")
                    time.sleep(0.05)
                if not (self.home / "daemon.json").exists():
                    self._fail("daemon did not start")
            else:
                self.process = _shared.process
            self._connection_refresh()
            return self

    def _connection_refresh(self):
        global _daemon_pid, daemon_boots
        self.connection = json.loads((self.home / "daemon.json").read_text())
        self.base = f"http://127.0.0.1:{self.connection['port']}"
        if self.connection["pid"] != _daemon_pid:
            # A new PID is valid only after the old daemon has exited.
            if _daemon_pid is not None:
                try:
                    os.kill(_daemon_pid, 0)
                except ProcessLookupError:
                    pass
                else:
                    raise AssertionError("second concurrent E2E daemon started")
            _daemon_pid = self.connection["pid"]
            daemon_boots += 1

    def restart(self, *, crash=False):
        global restart_seconds
        started = time.monotonic()
        if crash:
            os.kill(self.connection["pid"], signal.SIGKILL)
        else:
            self.api("/shutdown", {}).close()
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                try:
                    os.kill(self.connection["pid"], 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self._fail("daemon did not stop")
        self.cli("sessions")
        self._connection_refresh()
        restart_seconds += time.monotonic() - started

    def _fail(self, message):
        log = self.home / "daemon.log"
        raise AssertionError(message + ("\n" + log.read_text() if log.exists() else ""))

    def api(self, path, body=None, *, method=None):
        request = urllib.request.Request(
            self.base + path,
            data=None if body is None else json.dumps(body).encode(),
            method=method,
            headers={
                "Authorization": "Bearer " + self.connection["token"],
                "Content-Type": "application/json",
            },
        )
        try:
            return urllib.request.urlopen(request, timeout=20)
        except urllib.error.HTTPError as failure:
            payload = failure.read()
            raise urllib.error.HTTPError(
                failure.url,
                failure.code,
                failure.msg + ": " + payload.decode(errors="replace"),
                failure.headers,
                io.BytesIO(payload),
            ) from failure

    def store_secrets(self, section, value):
        """Replaces one creds.json section, where the daemon keeps every secret."""
        path = self.home / "creds.json"
        creds = json.loads(path.read_text()) if path.exists() else {}
        creds[section] = value
        path.write_text(json.dumps(creds))
        path.chmod(0o600)

    def cli(self, *args):
        result = subprocess.run(
            [str(ROOT / "cli/bin/albedo"), *args],
            cwd=ROOT,
            env=self.env,
            text=True,
            capture_output=True,
            timeout=45,
        )
        if result.returncode:
            self._fail(result.stdout + result.stderr)
        return result.stdout

    def session(self, workspace=None):
        with _config_lock:
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
        with _config_lock:
            if not self._concurrent:
                for name, content in self._saved.items():
                    path = self.home / name
                    if content is None:
                        path.unlink(missing_ok=True)
                    else:
                        path.write_bytes(content)
            if self._owns_provider:
                self.provider.close()
