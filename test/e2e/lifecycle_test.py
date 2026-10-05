"""CLI attachment and startup must preserve an independently owned real daemon."""

import json
import os
import pty
import select
import signal
import socket
import stat
import subprocess
import sys
import termios
import time
import unittest

from harness import Albedo, Provider, exclusive, operation_id, python, text


def direct_start(daemon):
    daemon.start_launcher()
    daemon.await_ready()


def runtime_limits(app):
    cookie = (app.home / "inspect.cookie").read_text().strip()
    node = f"albedo_{app.daemon._pid}@{socket.gethostname().split('.')[0]}"
    expression = (
        f"Node = '{node}', "
        "Limits = [rpc:call(Node, erlang, system_info, [Key]) "
        "|| Key <- [process_limit, port_limit, schedulers_online]], "
        "io:put_chars(json:encode(Limits)), halt()."
    )
    result = subprocess.run(
        [
            "erl",
            "+S",
            "2:2",
            "-sname",
            f"lifecycle_probe_{app.daemon._pid}",
            "-setcookie",
            cookie,
            "-noshell",
            "-eval",
            expression,
        ],
        capture_output=True,
        text=True,
        timeout=20,
        check=True,
    )
    return json.loads(result.stdout)


def gated_launcher(app):
    """A pipe barrier signals the real launch attempt before letting it exec."""
    original = app.env["ALBEDO_DAEMON"]
    started, release = app.root / "launcher-started", app.root / "launcher-release"
    os.mkfifo(started)
    os.mkfifo(release)
    attempts = app.root / "launcher-attempts"
    wrapper = app.root / "gated-launcher"
    wrapper.write_text(
        f"#!{sys.executable}\n"
        "import os\n"
        f"with open({str(attempts)!r}, 'a') as attempts:\n"
        "    attempts.write(str(os.getpid()) + '\\n')\n"
        "    attempts.flush()\n"
        f"with open({str(started)!r}, 'w') as ready:\n"
        "    ready.write(str(os.getpid()) + '\\n')\n"
        f"with open({str(release)!r}, 'rb', buffering=0) as gate:\n"
        "    gate.read(1)\n"
        f"os.execv({original!r}, [{original!r}])\n"
    )
    wrapper.chmod(0o700)
    app.env["ALBEDO_DAEMON"] = str(wrapper)
    return started, release, attempts


class TerminalCommand:
    def __init__(self, app, *arguments):
        self.master, slave = pty.openpty()
        termios.tcsetwinsize(slave, (24, 100))
        self.process = app.daemon.start_cli(
            *arguments, stdin=slave, stdout=slave, stderr=slave
        )
        os.close(slave)
        self.output = b""

    def prompt(self, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            readable, _, _ = select.select(
                [self.master], [], [], max(0, deadline - time.monotonic())
            )
            if readable:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError as error:
                    raise AssertionError(
                        "CLI exited before restart prompt: "
                        + self.output.decode(errors="replace")
                    ) from error
                self.output += chunk
                if b"\x1b[6n" in chunk:
                    os.write(self.master, b"\x1b[1;1R")
                if b"\x1b[c" in chunk:
                    os.write(self.master, b"\x1b[?1;2c")
                if b"[y/N]" in self.output or b"[Y/n]" in self.output:
                    return
        raise AssertionError(
            "CLI did not offer a restart: " + self.output.decode(errors="replace")
        )

    def answer(self, value):
        os.write(self.master, (value + "\r").encode())
        result = self.process.wait(timeout=20)
        os.close(self.master)
        return result


# exclusive: owns daemon startup and restart behavior
@exclusive
class LifecycleTest(unittest.TestCase):
    def test_standalone_default_home_authentication_and_vm_defaults_match_cli(self):
        def prepare(app):
            app.home = app.daemon.home = app.root / "user-home" / ".albedo"
            app.home.mkdir(mode=0o755)
            app.env.pop("ALBEDO_HOME")
            app.env.pop("ALBEDO_TOKEN", None)
            app.env["ALBEDO_INSPECT"] = "1"
            app.daemon.boot_action = direct_start

        with Albedo(prepare=prepare) as app:
            direct = dict(app.connection)
            self.assertGreaterEqual(len(direct["token"]), 32)
            self.assertEqual(stat.S_IMODE(app.home.stat().st_mode), 0o700)
            self.assertEqual(
                stat.S_IMODE((app.home / "daemon.json").stat().st_mode), 0o600
            )
            connection = socket.create_connection(
                ("127.0.0.1", direct["port"]), timeout=5
            )
            with connection:
                connection.sendall(
                    f"GET /server HTTP/1.1\r\nHost: localhost:{direct['port']}\r\nConnection: close\r\n\r\n".encode()
                )
                self.assertIn(b"401", connection.recv(1024).split(b"\r\n", 1)[0])
            direct_limits = runtime_limits(app)
            session = app.session()
            app.prompt(session, "independent daemon is usable").close()
            app.idle(session)
            self.assertIn(
                "ok",
                [
                    part["text"]
                    for entry in app.history(session)["items"]
                    for part in entry["content"]
                    if part["kind"] == "text"
                ],
            )
            self.assertEqual(app.connection, direct)
            app.restart()
            self.assertNotEqual(app.connection["pid"], direct["pid"])
            self.assertNotEqual(app.connection["token"], direct["token"])
            self.assertEqual(runtime_limits(app), direct_limits)
            app.restart(
                prepare=lambda fixture: fixture.env.update(
                    ERL_FLAGS=fixture.env["ERL_FLAGS"] + " +P 131072 +Q 32768",
                    ALBEDO_TOKEN="operator-chosen-authentication-token",
                )
            )
            self.assertEqual(runtime_limits(app)[:2], [131072, 32768])
            self.assertEqual(
                app.connection["token"], "operator-chosen-authentication-token"
            )
            self.assertEqual(app.api("/server").status, 200)

    def test_cancelling_cli_startup_wait_leaves_the_started_daemon_owned(self):
        captured = {}

        def prepare(app):
            started, release, attempts = gated_launcher(app)

            def start(daemon):
                command = daemon.start_cli(
                    "daemon", stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                with started.open() as ready:
                    captured["child"] = int(ready.readline())
                adopted = False
                try:
                    command.send_signal(signal.SIGINT)
                    stdout, stderr = command.communicate(timeout=5)
                    captured["cancelled"] = command.returncode
                    captured["output"] = stdout + stderr
                    with release.open("wb", buffering=0) as gate:
                        gate.write(b"x")
                    daemon.await_ready()
                    adopted = True
                finally:
                    if not adopted:
                        try:
                            os.kill(captured["child"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                captured["attempts"] = attempts.read_text().splitlines()

            app.daemon.boot_action = start

        with Albedo(prepare=prepare) as app:
            self.assertNotEqual(captured["cancelled"], 0, captured["output"])
            self.assertEqual(app.connection["pid"], captured["child"])
            self.assertEqual(len(captured["attempts"]), 1)
            session = app.session()
            app.prompt(session, "daemon survived waiter cancellation").close()
            app.idle(session)
            self.assertIn(
                "ok",
                [
                    part["text"]
                    for entry in app.history(session)["items"]
                    for part in entry["content"]
                    if part["kind"] == "text"
                ],
            )

    def test_simultaneous_cli_starters_converge_on_one_real_execution(self):
        captured = {}

        def prepare(app):
            started, release, attempts = gated_launcher(app)

            def start(daemon):
                first = daemon.start_cli(
                    "daemon", stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                second = daemon.start_cli(
                    "daemon", stdout=subprocess.PIPE, stderr=subprocess.PIPE
                )
                with started.open() as ready:
                    captured["owner"] = int(ready.readline())
                adopted = False
                try:
                    with release.open("wb", buffering=0) as gate:
                        gate.write(b"x")
                    captured["outputs"] = [
                        command.communicate(timeout=20) for command in (first, second)
                    ]
                    captured["codes"] = [first.returncode, second.returncode]
                    daemon.await_ready()
                    adopted = True
                finally:
                    if not adopted:
                        try:
                            os.kill(captured["owner"], signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                captured["attempts"] = attempts.read_text().splitlines()

            app.daemon.boot_action = start

        with Albedo(prepare=prepare) as app:
            self.assertEqual(captured["codes"], [0, 0], captured["outputs"])
            self.assertEqual(captured["attempts"], [str(app.connection["pid"])])
            self.assertEqual(app.connection["pid"], captured["owner"])
            self.assertEqual(app.api("/sessions").status, 200)

    def test_compatible_other_build_is_kept_without_a_terminal_and_explicit_yes_restarts(
        self,
    ):
        def prepare(app):
            app.env["ALBEDO_BUILD"] = "independent-compatible-build"
            app.daemon.boot_action = direct_start

        with Albedo(prepare=prepare) as app:
            previous = dict(app.connection)
            self.assertEqual(previous["build"], "independent-compatible-build")
            # The daemon records the content digest of the code it runs, so a
            # client can prove a build difference without a label.
            self.assertRegex(previous["digest"], r"^[0-9a-f]{64}$")
            app.env.pop("ALBEDO_BUILD")
            app.cli("daemon")
            self.assertEqual(
                json.loads((app.home / "daemon.json").read_text()), previous
            )
            terminal = TerminalCommand(app, "daemon")
            terminal.prompt()
            self.assertEqual(terminal.answer(""), 0)
            self.assertEqual(
                json.loads((app.home / "daemon.json").read_text()), previous
            )
            for cancel in ("\x03", "\x04"):
                terminal = TerminalCommand(app, "daemon")
                terminal.prompt()
                self.assertNotEqual(terminal.answer(cancel), 0)
                self.assertEqual(
                    json.loads((app.home / "daemon.json").read_text()), previous
                )
            terminal = TerminalCommand(app, "daemon")
            terminal.prompt()
            self.assertEqual(terminal.answer("y"), 0)
            app.daemon._refresh()
            self.assertNotEqual(app.connection["pid"], previous["pid"])
            self.assertNotEqual(app.connection["token"], previous["token"])

    def test_restart_confirmation_cannot_replace_a_newer_daemon(self):
        with Albedo() as app:
            terminal = TerminalCommand(app, "daemon")
            terminal.prompt()
            app.restart()
            replacement = dict(app.connection)
            self.assertNotEqual(terminal.answer("y"), 0)
            self.assertEqual(
                json.loads((app.home / "daemon.json").read_text()), replacement
            )
            self.assertEqual(app.api("/server").status, 200)

    def test_explicit_upgrade_recovers_history_receipt_and_uncertain_tool_without_repeating_effect(
        self,
    ):
        fixture = {}

        def script(request):
            messages = request["messages"]
            if any(
                "daemon restart" in str(message.get("content", ""))
                for message in messages
            ):
                return text("recovered after upgrade")
            if messages[-1]["role"] == "tool":
                return text("tool finished")
            return python(
                "from pathlib import Path\nimport threading\n"
                f"with Path({str(fixture['effect'])!r}).open('a') as effect:\n"
                "    effect.write('effect applied\\n')\n"
                "    effect.flush()\n"
                "threading.Event().wait(60)"
            )

        provider = Provider(script)
        self.addCleanup(provider.close)
        with Albedo(provider) as app:
            fixture["effect"] = app.workspace / "effect"
            session = app.session()
            operation = operation_id()
            app.api(
                f"/sessions/{session}/inputs/{operation}",
                {"kind": "message", "text": "apply an effect then wait"},
                method="PUT",
            ).close()
            deadline = time.monotonic() + 20
            while (
                not fixture["effect"].exists()
                or fixture["effect"].read_text() != "effect applied\n"
            ):
                if time.monotonic() > deadline:
                    app._fail("tool never published its external effect")
                time.sleep(0.02)
            self.assertTrue(
                json.load(app.api(f"/sessions/{session}?tail=0"))["status"]["phase"]
                == "running"
            )
            previous = dict(app.connection)
            terminal = TerminalCommand(app, "daemon")
            terminal.prompt()
            self.assertEqual(terminal.answer("y"), 0)
            app.daemon._refresh()
            self.assertNotEqual(app.connection["pid"], previous["pid"])
            app.idle(session)
            receipt = json.load(app.api(f"/sessions/{session}/inputs/{operation}"))
            self.assertEqual(receipt["delivery"], "committed")
            self.assertEqual(receipt["turn"]["state"], "abandoned")
            entries = app.history(session)["items"]
            self.assertEqual(
                sum(entry["input_id"] == operation for entry in entries), 1
            )
            self.assertTrue(
                any(
                    entry["kind"] == "note"
                    and any(
                        part["kind"] == "text" and "restart" in part["text"]
                        for part in entry["content"]
                    )
                    for entry in entries
                )
            )
            self.assertTrue(
                any(
                    part["kind"] == "text" and part["text"] == "recovered after upgrade"
                    for entry in entries
                    for part in entry["content"]
                )
            )
            self.assertEqual(fixture["effect"].read_text(), "effect applied\n")

    def test_failed_discovery_publication_exits_and_releases_home_for_retry(self):
        captured = {}

        def prepare(app):
            def start(daemon):
                blocked = app.home / "daemon.json"
                blocked.mkdir()
                process = daemon.start_launcher()
                captured["exit"] = process.wait(timeout=20)
                captured["pid"] = process.pid
                blocked.rmdir()

            app.daemon.boot_action = start

        with Albedo(prepare=prepare) as app:
            self.assertNotEqual(captured["exit"], 0)
            self.assertNotEqual(app.connection["pid"], captured["pid"])
            self.assertEqual(app.api("/server").status, 200)
