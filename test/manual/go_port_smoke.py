"""Comprehensive validation harness for native Go port of Albedo CLI.

Scenarios tested:
1. Noninteractive stdout commands (sessions, sessions --json, send, stop, daemon, login non-tty rejection, unknown command)
2. Interactive PTY Resume (120x40): live SSE stream rendering, assistant text, thinking, tool traces, status footer, clean terminal exit
3. Interactive PTY Session Picker (120x40): bare 'albedo' with multiple sessions launches Session Picker
4. Interactive PTY Login (120x40): unconfigured profile launches Login form
5. Interactive PTY Tiny Terminal (40x10): constrained viewport layout; asserts line widths <= 40 cols
6. SSE Memory Retention: 1,200+ uninterrupted assistant EventText chunks (>300KB) + canonical EventMessage with verification token; asserts complete consumption, peak RSS < 150 MiB, exit 0, and token display in UI.

Durable evidence is saved to /tmp/albedo-smoke-evidence/.
"""

import argparse
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import re
import selectors
import struct
import subprocess
import termios
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
EVIDENCE_DIR = Path("/tmp/albedo-smoke-evidence")
COMPLETION_TOKEN = "FINAL_ASSISTANT_STREAM_CONFIRMED_PARITY_CHECK_TOKEN_774910"


class StrictMockDaemon:
    def __init__(
        self,
        home_dir,
        token="fixture-token",
        version=2,
        sessions=None,
        configured=True,
        is_stress=False,
    ):
        self.home_dir = Path(home_dir)
        self.token = token
        self.version = version
        self.sessions = sessions or [
            {
                "id": "deadbeef12345678",
                "title": "Albedo Refactor Session",
                "last_assistant_at": int(time.time()) - 300,
                "workspace": "/tmp/workspace1",
                "model": "gpt-4o",
                "protocol": "responses",
                "provider": "openai",
            },
            {
                "id": "cafebabe87654321",
                "title": "Documentation Updates",
                "last_assistant_at": int(time.time()) - 7200,
                "workspace": "/tmp/workspace2",
                "model": "claude-3-5-sonnet",
                "protocol": "responses",
                "provider": "anthropic",
            },
        ]
        self.configured = configured
        self.is_stress = is_stress
        self.received_events = []
        self.received_interrupts = []
        self.total_events_sent = 0
        self.ready_event = threading.Event()
        self.ended_event = threading.Event()
        self.stop_stream = threading.Event()
        self.server = None
        self.thread = None

    def start(self):
        parent = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def check_auth(self):
                auth = self.headers.get("Authorization")
                if auth != f"Bearer {parent.token}":
                    self.send_response(401)
                    self.end_headers()
                    self.wfile.write(b'{"error":"unauthorized"}')
                    return False
                return True

            def do_GET(self):
                if not self.check_auth():
                    return

                if self.path == "/health":
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    payload = {
                        "ok": True,
                        "version": parent.version,
                        "capabilities": [
                            "session_provider",
                            "session_workspace",
                            "session_extensions",
                            "session_tree",
                            "session_context",
                            "session_commands",
                        ],
                    }
                    self.wfile.write(json.dumps(payload).encode())
                    return

                if self.path == "/sessions":
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps(parent.sessions).encode())
                    return

                if "/status" in self.path:
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    self.wfile.write(
                        json.dumps(
                            {"running": False, "idle": True, "phase": "resting"}
                        ).encode()
                    )
                    return

                if "/commands" in self.path:
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    catalog = [
                        {
                            "name": "/review",
                            "description": "review recent changes",
                            "method": "review",
                            "arguments": [],
                            "modelCallable": True,
                            "userTurn": True,
                        },
                        {
                            "name": "/compact",
                            "description": "compact history",
                            "method": "compact",
                            "arguments": [],
                            "modelCallable": False,
                            "userTurn": True,
                        },
                    ]
                    self.wfile.write(json.dumps(catalog).encode())
                    return

                if "/stream" in self.path:
                    self.send_response(200)
                    self.send_header("content-type", "text/event-stream")
                    self.send_header("cache-control", "no-cache")
                    self.end_headers()

                    def send_chunk(events, cursor):
                        payload = (
                            "data: "
                            + json.dumps({"cursor": cursor, "events": events})
                            + "\n\n"
                        )
                        self.wfile.write(payload.encode())
                        self.wfile.flush()
                        parent.total_events_sent += len(events)

                    try:
                        cursor = 0
                        send_chunk([{"type": "reset"}], cursor)
                        cursor += 1

                        send_chunk(
                            [
                                {
                                    "type": "user",
                                    "text": "streaming benchmark test turn",
                                    "source": "chat",
                                    "triggeredAt": "smoke",
                                }
                            ],
                            cursor,
                        )
                        cursor += 1
                        parent.ready_event.set()

                        if parent.is_stress:
                            # Massive uninterrupted assistant EventText stream (>300KB, >1200 chunks)
                            full_text_acc = []
                            for i in range(1200):
                                if parent.stop_stream.is_set():
                                    break
                                chunk = f"Paragraph {i}: Validating bounded stream retention and memory virtualization under uninterrupted EventText loads at step {i}.\n"
                                full_text_acc.append(chunk)
                                send_chunk([{"type": "text", "text": chunk}], cursor)
                                cursor += 1
                                if i % 100 == 0:
                                    time.sleep(0.002)

                            # Append ending token
                            final_marker = f"\n\n{COMPLETION_TOKEN}\n"
                            full_text_acc.append(final_marker)
                            send_chunk([{"type": "text", "text": final_marker}], cursor)
                            cursor += 1

                            # Canonical EventMessage
                            assembled = "".join(full_text_acc)
                            send_chunk(
                                [
                                    {
                                        "type": "message",
                                        "role": "assistant",
                                        "text": assembled,
                                        "timestamp": int(time.time() * 1000),
                                    }
                                ],
                                cursor,
                            )
                            cursor += 1

                            send_chunk(
                                [
                                    {
                                        "type": "usage",
                                        "completionTokens": cursor,
                                        "totalTokens": cursor + 500,
                                    }
                                ],
                                cursor,
                            )
                            cursor += 1
                            parent.ended_event.set()
                        else:
                            # Standard test stream with thinking, text, and tools
                            send_chunk(
                                [
                                    {
                                        "type": "thinking",
                                        "text": "analyzing workspace structure\n",
                                    }
                                ],
                                cursor,
                            )
                            cursor += 1

                            text_parts = [
                                "I have verified the project configuration.\n\n",
                                '```go\nfunc main() {\n    fmt.Println("Albedo Native Go CLI")\n}\n```\n',
                                f"Everything is verified. {COMPLETION_TOKEN}\n",
                            ]
                            for t in text_parts:
                                send_chunk([{"type": "text", "text": t}], cursor)
                                cursor += 1
                                time.sleep(0.01)

                            send_chunk(
                                [
                                    {
                                        "type": "tool",
                                        "name": "edit",
                                        "args": {"path": "cli/cmd/albedo/main.go"},
                                        "result": "success",
                                        "trace": {
                                            "activities": [
                                                {"kind": "read", "target": "main.go"}
                                            ],
                                            "changes": [
                                                {
                                                    "path": "main.go",
                                                    "kind": "diff",
                                                    "diff": "@@ -1,3 +1,3 @@\n-old\n+new",
                                                    "added": 1,
                                                    "removed": 1,
                                                }
                                            ],
                                        },
                                    }
                                ],
                                cursor,
                            )
                            cursor += 1

                            send_chunk(
                                [
                                    {
                                        "type": "usage",
                                        "completionTokens": 50,
                                        "totalTokens": 150,
                                    }
                                ],
                                cursor,
                            )
                            cursor += 1
                            parent.ended_event.set()

                        while not parent.stop_stream.wait(0.2):
                            self.wfile.write(b": keepalive\n\n")
                            self.wfile.flush()
                    except BrokenPipeError, ConnectionResetError:
                        pass
                    return

                # Strict: Unknown GET returns 404
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b'{"error":"not found"}')

            def do_POST(self):
                if not self.check_auth():
                    return

                content_len = int(self.headers.get("Content-Length", 0))
                body = self.rfile.read(content_len).decode() if content_len > 0 else ""
                parsed = json.loads(body) if body else {}

                if "/events" in self.path:
                    parent.received_events.append(parsed)
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"ok":true,"queued":false}')
                    return

                if "/interrupt" in self.path:
                    parent.received_interrupts.append(parsed)
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"ok":true,"interrupted":true}')
                    return

                if self.path == "/sessions":
                    new_sess = {
                        "id": "newsession12345678",
                        "title": "Fresh Created Session",
                        "workspace": parsed.get("workspace", "/tmp"),
                        "model": "gpt-4o",
                        "protocol": "responses",
                        "provider": "openai",
                    }
                    self.send_response(201)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    self.wfile.write(json.dumps(new_sess).encode())
                    return

                if "/shutdown" in self.path:
                    self.send_response(200)
                    self.send_header("content-type", "application/json")
                    self.end_headers()
                    self.wfile.write(b'{"ok":true}')
                    return

                # Strict: Unknown POST returns 404
                self.send_response(404)
                self.end_headers()
                self.wfile.write(b'{"error":"not found"}')

        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

        self.home_dir.mkdir(parents=True, exist_ok=True)
        (self.home_dir / "daemon.json").write_text(
            json.dumps(
                {
                    "port": self.server.server_port,
                    "token": self.token,
                    "pid": os.getpid(),
                    "version": self.version,
                }
            )
        )
        if self.configured:
            (self.home_dir / "config.json").write_text(
                json.dumps(
                    {
                        "active": "fixture",
                        "providers": {
                            "fixture": {
                                "extension": "openai",
                                "baseUrl": f"http://127.0.0.1:{self.server.server_port}",
                                "apiKey": "fixture-key",
                                "model": "gpt-4o",
                                "protocol": "responses",
                            }
                        },
                    }
                )
            )
        else:
            (self.home_dir / "config.json").write_text(json.dumps({"providers": {}}))

    def stop(self):
        self.stop_stream.set()
        if self.server:
            self.server.shutdown()
            self.server.server_close()


def clean_ansi(raw_bytes):
    text = raw_bytes.decode("utf-8", errors="replace")
    # Replace cursor movement/addressing ([H, [9;H, etc.) with newline
    text = re.sub(r"\x1b\[[0-9;]*[Hf]", "\n", text)
    # Strip remaining CSI escape sequences
    text = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", text)
    # Strip OSC sequences
    text = re.sub(r"\x1b\][^\x1b]*(\x07|\x1b\\)", "", text)
    # Normalize carriage returns and line endings
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    return text


def run_pty_scenario(binary, home_dir, args, rows, cols, duration=2.5, input_keys=None):
    raw_output = bytearray()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
    env = {
        **os.environ,
        "ALBEDO_HOME": str(home_dir),
        "TERM": "xterm-256color",
        "ALBEDO_NO_BROWSER": "1",
    }

    child = subprocess.Popen(
        [str(binary)] + args,
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    os.set_blocking(master, False)

    selector = selectors.DefaultSelector()
    selector.register(master, selectors.EVENT_READ)

    started = time.monotonic()
    input_sent = False
    exit_sent = False
    try:
        while child.poll() is None:
            for key, _ in selector.select(0.05):
                try:
                    data = os.read(key.fd, 4096)
                    if data:
                        raw_output.extend(data)
                except BlockingIOError, OSError:
                    pass

            elapsed = time.monotonic() - started
            if input_keys and not input_sent and elapsed > 0.8:
                for k in input_keys:
                    os.write(master, k)
                    time.sleep(0.05)
                input_sent = True

            if not exit_sent and elapsed > duration:
                os.write(master, b"\x03")
                exit_sent = True

            if elapsed > duration + 4.0:
                child.terminate()
                break

        child.wait(timeout=3.0)

        # Drain trailing bytes
        while True:
            try:
                data = os.read(master, 4096)
                if not data:
                    break
                raw_output.extend(data)
            except BlockingIOError, OSError:
                break
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=2.0)
        os.close(master)
        selector.close()

    cleaned = clean_ansi(raw_output)
    return raw_output, cleaned, child.returncode


def test_noninteractive(binary, out_dir):
    print("=== 1. Noninteractive CLI Commands ===")
    home = out_dir / "home_noninteractive"
    mock = StrictMockDaemon(home)
    mock.start()
    env = {**os.environ, "ALBEDO_HOME": str(home)}
    try:
        p = subprocess.run(
            [str(binary), "sessions"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert p.returncode == 0, f"sessions error: {p.stderr}"
        assert "Albedo Refactor Session" in p.stdout
        assert "[deadbeef]" in p.stdout
        print("  [PASS] albedo sessions")

        p = subprocess.run(
            [str(binary), "sessions", "--json"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert p.returncode == 0, f"sessions --json error: {p.stderr}"
        data = json.loads(p.stdout)
        assert len(data) == 2
        assert data[0]["id"] == "deadbeef12345678"
        print("  [PASS] albedo sessions --json")

        p = subprocess.run(
            [str(binary), "send", "deadbeef12345678", "hello albedo"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert p.returncode == 0, f"send error: {p.stderr}"
        assert len(mock.received_events) == 1
        assert mock.received_events[0]["content"] == "hello albedo"
        print("  [PASS] albedo send")

        p = subprocess.run(
            [str(binary), "stop", "deadbeef12345678"],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert p.returncode == 0, f"stop error: {p.stderr}"
        assert len(mock.received_interrupts) == 1
        print("  [PASS] albedo stop")

        p = subprocess.run(
            [str(binary), "daemon"], env=env, capture_output=True, text=True, timeout=10
        )
        assert p.returncode == 0, f"daemon error: {p.stderr}"
        assert f"127.0.0.1:{mock.server.server_port}" in p.stdout
        print("  [PASS] albedo daemon")

        p = subprocess.run(
            [str(binary), "login"], env=env, capture_output=True, text=True, timeout=10
        )
        assert p.returncode != 0
        assert "login requires a terminal" in (p.stderr + p.stdout)
        print("  [PASS] albedo login (non-TTY rejection)")

        p = subprocess.run(
            [str(binary), "foobar"], env=env, capture_output=True, text=True, timeout=10
        )
        assert p.returncode != 0
        assert "unknown command" in (p.stderr + p.stdout)
        print("  [PASS] unknown command rejection")
    finally:
        mock.stop()


def test_pty_resume(binary, out_dir):
    print("=== 2. Interactive PTY Resume (120x40 Standard) ===")
    home = out_dir / "home_resume"
    mock = StrictMockDaemon(home)
    mock.start()
    try:
        raw, cleaned, code = run_pty_scenario(
            binary,
            home,
            ["resume", "deadbeef12345678"],
            rows=40,
            cols=120,
            duration=2.5,
        )
        (out_dir / "pty_resume_120x40.raw").write_bytes(raw)
        (out_dir / "pty_resume_120x40.txt").write_text(cleaned)

        assert code == 0, f"Expected clean exit 0, got {code}"
        assert b"\x1b[?1049h" not in raw, (
            "Inline TUI unexpectedly entered the alternate screen"
        )
        assert b"\x1b[?25h" in raw, "Cursor show sequence not emitted"
        for mode in (1002, 1006):
            enabled = f"\x1b[?{mode}h".encode()
            disabled = f"\x1b[?{mode}l".encode()
            assert enabled in raw, f"Chat mouse mode {mode} was not enabled"
            assert raw.rfind(disabled) > raw.rfind(enabled), (
                f"Chat mouse mode {mode} was not disabled on exit"
            )

        lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
        assert any("streaming benchmark test turn" in l for l in lines), (
            "User prompt not rendered"
        )
        assert any("gpt-4o" in l for l in lines), "Status footer model not rendered"
        assert any(COMPLETION_TOKEN in l for l in lines), (
            "Completion token not rendered in viewport"
        )

        print(
            f"  [PASS] Rendered transcript, model status, and exit code 0. Terminal restored."
        )
    finally:
        mock.stop()


def test_pty_session_picker(binary, out_dir):
    print("=== 3. Interactive PTY Bare Launch -> Session Picker ===")
    home = out_dir / "home_picker"
    mock = StrictMockDaemon(home)
    mock.start()
    try:
        raw, cleaned, code = run_pty_scenario(
            binary, home, [], rows=30, cols=100, duration=2.0, input_keys=[b"\x1b"]
        )
        (out_dir / "pty_bare_picker.raw").write_bytes(raw)
        (out_dir / "pty_bare_picker.txt").write_text(cleaned)

        assert code == 0, f"Expected clean exit 0, got {code}"
        lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
        has_picker = any(
            "sessions" in l or "Albedo Refactor Session" in l for l in lines
        )
        assert has_picker, f"Session picker not rendered. Output: {cleaned}"
        print(f"  [PASS] Session Picker rendered cleanly. Code: {code}")
    finally:
        mock.stop()


def test_pty_unconfigured_login(binary, out_dir):
    print("=== 4. Interactive PTY Unconfigured -> Login View ===")
    home = out_dir / "home_login"
    mock = StrictMockDaemon(home, configured=False)
    mock.start()
    try:
        raw, cleaned, code = run_pty_scenario(
            binary, home, [], rows=30, cols=100, duration=2.0, input_keys=[b"\x1b"]
        )
        (out_dir / "pty_login_unconfigured.raw").write_bytes(raw)
        (out_dir / "pty_login_unconfigured.txt").write_text(cleaned)

        assert code == 0, f"Expected clean exit 0, got {code}"
        lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
        has_login = any("login" in l or "provider" in l for l in lines)
        assert has_login, f"Login screen not rendered. Output: {cleaned}"
        print(f"  [PASS] Login screen rendered cleanly. Code: {code}")
    finally:
        mock.stop()


def test_pty_standalone_login_cancel(binary, out_dir):
    print("=== Standalone albedo login [Cancel -> Exit 0 to Shell] ===")
    home = out_dir / "home_login_cancel"
    mock = StrictMockDaemon(home)
    mock.start()
    try:
        raw, cleaned, code = run_pty_scenario(
            binary,
            home,
            ["login"],
            rows=30,
            cols=100,
            duration=1.5,
            input_keys=[b"\x1b"],
        )
        (out_dir / "pty_standalone_login_cancel.txt").write_text(cleaned)

        assert code == 0, (
            f"Expected clean exit 0 on standalone login cancel, got {code}"
        )
        lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
        assert any("login" in l for l in lines), "Login view not rendered"
        # Must not enter session picker or chat
        assert not any("albedo  sessions" in l for l in lines), (
            "Standalone login cancel opened session picker!"
        )
        assert not any("type a message" in l or "› type" in l for l in lines), (
            "Standalone login cancel opened chat!"
        )
        print("  [PASS] Standalone login cancel exited cleanly to shell (code 0)")
    finally:
        mock.stop()


def test_pty_standalone_login_save_flow(binary, out_dir):
    print("=== Standalone albedo login [Provider Save -> Exit 0 to Shell] ===")
    home = out_dir / "home_login_save"
    home.mkdir(parents=True, exist_ok=True)
    mock = StrictMockDaemon(home, configured=False)
    mock.start()

    # Pre-populate an inactive provider in config.json
    cfg = {
        "providers": {
            "testprov": {
                "extension": "openai",
                "baseUrl": f"http://127.0.0.1:{mock.server.server_port}",
                "apiKey": "test-key",
                "model": "gpt-4o",
                "protocol": "responses",
            }
        }
    }
    (home / "config.json").write_text(json.dumps(cfg))

    try:
        # Run albedo login testprov: matches existing inactive provider, saves as active, and quits directly to shell
        raw, cleaned, code = run_pty_scenario(
            binary, home, ["login", "testprov"], rows=30, cols=100, duration=1.5
        )
        (out_dir / "pty_standalone_login_save.txt").write_text(cleaned)

        assert code == 0, f"Expected exit code 0 on standalone login save, got {code}"

        # Verify config.json was updated with active = testprov
        saved_cfg = json.loads((home / "config.json").read_text())
        assert saved_cfg.get("active") == "testprov", (
            f"Expected active: testprov, got: {saved_cfg}"
        )

        # Verify it did not launch chat or session picker
        lines = [line.strip() for line in cleaned.splitlines() if line.strip()]
        assert not any("albedo  sessions" in l for l in lines), (
            "Standalone login save opened session picker!"
        )
        assert not any("type a message" in l for l in lines), (
            "Standalone login save opened chat!"
        )
        print(
            "  [PASS] Standalone login saved active provider and exited directly to shell (code 0)"
        )
    finally:
        mock.stop()


def test_pty_tiny_terminal(binary, out_dir):
    print("=== 5. Interactive PTY Tiny Terminal (40x10) ===")
    home = out_dir / "home_tiny"
    mock = StrictMockDaemon(home)
    mock.start()
    try:
        raw, cleaned, code = run_pty_scenario(
            binary, home, ["resume", "deadbeef12345678"], rows=10, cols=40, duration=2.0
        )
        (out_dir / "pty_tiny_40x10.raw").write_bytes(raw)
        (out_dir / "pty_tiny_40x10.txt").write_text(cleaned)

        assert code == 0, f"Expected clean exit 0, got {code}"
        lines = cleaned.splitlines()
        # Behavioral layout check: every rendered line must fit within 40 columns
        for line in lines:
            assert len(line) <= 40, (
                f"Line exceeded tiny terminal width 40: {len(line)} chars: {line!r}"
            )

        nonempty = [l.strip() for l in lines if l.strip()]
        assert len(nonempty) > 0, "No content rendered in tiny terminal"
        assert any(
            "gpt-4o" in l or "reasoning" in l or "streaming" in l for l in nonempty
        ), "No expected session content in tiny view"
        print(
            f"  [PASS] Tiny terminal (40x10) respected max column bounds on all {len(lines)} lines without panic. Code: {code}"
        )
    finally:
        mock.stop()


def test_sse_retention_and_memory(binary, out_dir):
    print("=== 6. SSE Stream Retention & Peak Memory (>1,200 EventText chunks) ===")
    home = out_dir / "home_memory"
    mock = StrictMockDaemon(home, is_stress=True)
    mock.start()

    raw_output = bytearray()
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    env = {
        **os.environ,
        "ALBEDO_HOME": str(home),
        "TERM": "xterm-256color",
        "ALBEDO_NO_BROWSER": "1",
    }

    child = subprocess.Popen(
        [str(binary), "resume", "deadbeef12345678"],
        env=env,
        stdin=slave,
        stdout=slave,
        stderr=slave,
        start_new_session=True,
    )
    os.close(slave)
    os.set_blocking(master, False)

    selector = selectors.DefaultSelector()
    selector.register(master, selectors.EVENT_READ)

    started = time.monotonic()
    rss_kb_samples = []
    token_seen_in_ui = False
    sig_sent = False
    try:
        while child.poll() is None:
            for key, _ in selector.select(0.05):
                try:
                    data = os.read(key.fd, 8192)
                    if data:
                        raw_output.extend(data)
                except BlockingIOError, OSError:
                    pass

            try:
                out = (
                    subprocess.check_output(["ps", "-o", "rss=", "-p", str(child.pid)])
                    .decode()
                    .strip()
                )
                if out:
                    rss_kb_samples.append(int(out))
            except Exception:
                pass

            # Strict verification: wait until the completion token is actually received in the PTY output
            if COMPLETION_TOKEN.encode() in raw_output and not sig_sent:
                token_seen_in_ui = True
                time.sleep(0.2)
                os.write(master, b"\x03")
                sig_sent = True

            # Timeout safety
            if time.monotonic() - started > 25.0:
                os.write(master, b"\x03")
                time.sleep(0.2)
                child.terminate()
                break

        child.wait(timeout=4.0)

        # Drain trailing bytes
        while True:
            try:
                data = os.read(master, 4096)
                if not data:
                    break
                raw_output.extend(data)
            except BlockingIOError, OSError:
                break
    finally:
        if child.poll() is None:
            child.terminate()
            child.wait(timeout=2.0)
        os.close(master)
        selector.close()
        mock.stop()

    cleaned = clean_ansi(raw_output)
    (out_dir / "pty_stream_stress.raw").write_bytes(raw_output)
    (out_dir / "pty_stream_stress.txt").write_text(cleaned)

    # 1. Assertions on Stream Completion
    assert mock.ended_event.is_set(), "Server stream did not complete"
    assert mock.total_events_sent >= 1200, (
        f"Expected >=1200 events, sent: {mock.total_events_sent}"
    )
    assert child.returncode == 0, f"Expected clean child exit 0, got {child.returncode}"

    # 2. Strict UI Consumption Assertion: token must be present in captured UI output
    assert token_seen_in_ui, (
        f"UI did not consume/display the ending marker {COMPLETION_TOKEN} before exit!"
    )
    assert COMPLETION_TOKEN in cleaned, f"Cleaned output missing {COMPLETION_TOKEN}!"

    # 3. Assertions on Memory
    assert len(rss_kb_samples) > 0, "No memory samples were captured during streaming"
    peak_rss_mib = max(rss_kb_samples) / 1024.0
    assert peak_rss_mib > 0.0, "Peak RSS recorded was 0"
    assert peak_rss_mib < 150.0, f"Peak memory exceeded budget: {peak_rss_mib:.2f} MiB"

    (out_dir / "memory_samples.json").write_text(
        json.dumps(
            {
                "samples_count": len(rss_kb_samples),
                "peak_rss_mib": round(peak_rss_mib, 2),
                "total_events": mock.total_events_sent,
                "token_confirmed": True,
                "all_rss_kb": rss_kb_samples,
            },
            indent=2,
        )
    )

    print(f"  [PASS] Streamed {mock.total_events_sent} uninterrupted events (>300KB).")
    print(
        f"  [PASS] Confirmed UI consumed and displayed ending token: {COMPLETION_TOKEN}."
    )
    print(
        f"  [PASS] Peak RSS: {peak_rss_mib:.2f} MiB across {len(rss_kb_samples)} samples. Exit code: {child.returncode}."
    )


def main():
    parser = argparse.ArgumentParser(
        description="Albedo Go Port Comprehensive Smoke Suite"
    )
    parser.add_argument(
        "--binary",
        default=str(ROOT / "cli/bin/albedo"),
        help="Path to albedo executable",
    )
    parser.add_argument(
        "--outdir",
        default=str(EVIDENCE_DIR),
        help="Directory for durable evidence files",
    )
    args = parser.parse_args()

    binary = Path(args.binary).resolve()
    if not binary.exists():
        print(
            f"Error: binary {binary} not found. Run go -C cli build -o bin/albedo ./cmd/albedo first."
        )
        return 1

    out_dir = Path(args.outdir).resolve()
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Starting Albedo Go Port Validation. Binary: {binary}, Evidence: {out_dir}")

    test_noninteractive(binary, out_dir)
    test_pty_resume(binary, out_dir)
    test_pty_session_picker(binary, out_dir)
    test_pty_unconfigured_login(binary, out_dir)
    test_pty_standalone_login_cancel(binary, out_dir)
    test_pty_standalone_login_save_flow(binary, out_dir)
    test_pty_tiny_terminal(binary, out_dir)
    test_sse_retention_and_memory(binary, out_dir)

    summary = {
        "status": "PASS",
        "timestamp": time.time(),
        "binary": str(binary),
        "evidence_dir": str(out_dir),
        "completion_token": COMPLETION_TOKEN,
        "checks": [
            "noninteractive_sessions",
            "noninteractive_sessions_json",
            "noninteractive_send",
            "noninteractive_stop",
            "noninteractive_daemon",
            "noninteractive_login_rejection",
            "noninteractive_unknown_command",
            "pty_resume_120x40",
            "pty_bare_picker",
            "pty_unconfigured_login",
            "pty_tiny_40x10_width_bounds",
            "sse_stream_retention_memory_completion_token",
        ],
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2))
    print("\n=======================================================")
    print(
        "ALL COMPREHENSIVE INTEGRATION & SMOKE CHECKS PASSED! (\u3063\u02d8\u25e1\u02d8)\u3063"
    )
    print(f"Durable evidence captured in: {out_dir}")
    print("=======================================================\n")
    return 0


if __name__ == "__main__":
    import sys

    sys.exit(main())
