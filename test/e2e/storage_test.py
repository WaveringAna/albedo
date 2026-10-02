"""Offline cleanup and daemon startup must exclude each other, even without HTTP."""

from contextlib import closing
import hashlib
import json
import os
import pickle
import signal
import select
import sqlite3
import subprocess
import sys
import time
import unittest

from harness import Albedo, ROOT, exclusive

MAINTENANCE = ROOT / "cli/internal/storage/maintenance.py"


class StorageTests(unittest.TestCase):
    def helper(self, home, paths=()):
        helper = subprocess.Popen(
            [sys.executable, str(MAINTENANCE), str(home)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.addCleanup(self.close_helper, helper)
        assert helper.stdin is not None and helper.stdout is not None
        helper.stdin.write(json.dumps({"paths": [str(path) for path in paths]}) + "\n")
        helper.stdin.flush()
        self.assertEqual(json.loads(helper.stdout.readline()), {"ready": True})
        return helper

    def close_helper(self, helper):
        if helper.stdin and not helper.stdin.closed:
            helper.stdin.close()
        try:
            helper.wait(timeout=10)
        finally:
            if helper.poll() is None:
                helper.kill()
                helper.wait()
            if helper.stdout:
                helper.stdout.close()
            if helper.stderr:
                helper.stderr.close()

    def backup(self, app):
        path = app.home / "backups/albedo-before-image-store-1.sqlite"
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(b"approved backup")
        old = time.time() - 31 * 24 * 60 * 60
        os.utime(path, (old, old))
        return path

    @exclusive
    def test_maintenance_refuses_startup_and_second_cleanup_then_releases(self):
        with Albedo(providers={}) as app:
            backup = self.backup(app)

            def maintenance(app):
                database = app.home / "albedo.sqlite"
                before = hashlib.sha256(database.read_bytes()).digest()
                helper = self.helper(app.home, [backup])
                refused = subprocess.run(
                    [app.env["ALBEDO_DAEMON"]],
                    env=dict(app.env, ALBEDO_TOKEN="x" * 32),
                    cwd=ROOT,
                    capture_output=True,
                    timeout=20,
                )
                self.assertNotEqual(refused.returncode, 0)
                self.assertIn(b"storage is in use", refused.stdout + refused.stderr)
                self.assertEqual(hashlib.sha256(database.read_bytes()).digest(), before)
                cleanup = subprocess.run(
                    [
                        str(ROOT / "cli/bin/albedo"),
                        "storage",
                        "prune",
                        "--all",
                        "--yes",
                    ],
                    env=app.env,
                    cwd=ROOT,
                    capture_output=True,
                    timeout=20,
                )
                self.assertNotEqual(cleanup.returncode, 0)
                self.assertIn(b"storage is in use", cleanup.stderr)
                self.assertEqual(backup.read_bytes(), b"approved backup")
                self.close_helper(helper)
                self.assertEqual(helper.returncode, 0)

            app.restart(prepare=maintenance)
            self.assertEqual(backup.read_bytes(), b"approved backup")
            self.assertEqual(app.api("/health").status, 200)

    @exclusive
    @unittest.skipUnless(os.path.isdir("/proc/self"), "requires Linux process status")
    def test_unreachable_daemon_keeps_cleanup_out(self):
        with Albedo(providers={}) as app:
            backup = self.backup(app)
            pid = app.connection["pid"]
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                db.execute("CREATE TABLE reclaim(data BLOB)")
                db.execute("INSERT INTO reclaim VALUES(zeroblob(262144))")
                db.execute("DELETE FROM reclaim")
            before = app.cli("storage", "--json")
            os.kill(pid, signal.SIGSTOP)
            try:
                deadline = time.monotonic() + 10
                while True:
                    with open(f"/proc/{pid}/status") as status:
                        if "State:\tT" in status.read():
                            break
                    self.assertLess(
                        time.monotonic(), deadline, "daemon did not suspend"
                    )
                cleanup = subprocess.run(
                    [
                        str(ROOT / "cli/bin/albedo"),
                        "storage",
                        "prune",
                        "--all",
                        "--yes",
                    ],
                    env=app.env,
                    cwd=ROOT,
                    capture_output=True,
                    timeout=20,
                )
                self.assertNotEqual(cleanup.returncode, 0)
                self.assertIn(b"storage is in use", cleanup.stderr)
                self.assertEqual(backup.read_bytes(), b"approved backup")
                self.assertEqual(
                    json.loads(app.cli("storage", "--json")), json.loads(before)
                )
            finally:
                os.kill(pid, signal.SIGCONT)

    @exclusive
    @unittest.skipUnless(hasattr(os, "pidfd_open"), "requires Linux pidfds")
    def test_cli_death_and_signals_stop_its_mutation_helper(self):
        with Albedo(providers={}) as app:
            backup = self.backup(app)

            def maintenance(app):
                gate = app.home / "work-gate"
                os.mkfifo(gate)
                descriptor = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
                self.addCleanup(os.close, descriptor)
                tools = app.home / "test-tools"
                tools.mkdir()
                wrapper = tools / "python3"
                # Gate only unlink in the embedded maintenance script. Ordinary
                # inspection uses the real Python runtime without modification.
                held_unlink = (
                    "def held_unlink(path):\n"
                    f"    with open({str(gate)!r}, 'w') as pipe:\n"
                    "        pipe.write(str(os.getpid()) + '\\n')\n"
                    "    threading.Event().wait()\n"
                    "os.unlink = held_unlink\n"
                )
                wrapper.write_text(
                    f"#!{sys.executable}\n"
                    "import os, sys\n"
                    "script = sys.argv[2]\n"
                    "if 'def maintain(home)' in script:\n"
                    f"    gate = {held_unlink!r}\n"
                    "    script = script.replace('if __name__ ==', gate + 'if __name__ ==')\n"
                    "sys.argv = ['-c', *sys.argv[3:]]\n"
                    "exec(compile(script, '<maintenance>', 'exec'))\n"
                )
                wrapper.chmod(0o700)
                for death in (signal.SIGKILL, signal.SIGINT, signal.SIGTERM):
                    with self.subTest(signal=death):
                        command = subprocess.Popen(
                            [
                                str(ROOT / "cli/bin/albedo"),
                                "storage",
                                "prune",
                                "--backups",
                                "--yes",
                            ],
                            env=dict(
                                app.env, PATH=str(tools) + os.pathsep + app.env["PATH"]
                            ),
                            cwd=ROOT,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                        )
                        self.addCleanup(self.close_helper, command)
                        readable, _, _ = select.select([descriptor], [], [], 20)
                        self.assertEqual(
                            readable, [descriptor], "CLI never reached deletion"
                        )
                        helper_pid = int(os.read(descriptor, 1024))
                        helper_descriptor = os.pidfd_open(helper_pid)
                        try:
                            command.send_signal(death)
                            self.assertNotEqual(command.wait(timeout=10), 0)
                            readable, _, _ = select.select(
                                [helper_descriptor], [], [], 10
                            )
                            self.assertEqual(
                                readable,
                                [helper_descriptor],
                                "mutation helper survived CLI",
                            )
                            with sqlite3.connect(
                                app.home / "daemon.lock", timeout=0
                            ) as db:
                                db.execute("BEGIN EXCLUSIVE")
                            self.assertEqual(backup.read_bytes(), b"approved backup")
                        finally:
                            os.close(helper_descriptor)
                            self.close_helper(command)

            app.restart(prepare=maintenance)

    @exclusive
    def test_daemon_started_after_preview_refuses_cleanup_before_mutation(self):
        with Albedo(providers={}) as app:
            backup = self.backup(app)

            def maintenance(app):
                ready = app.home / "acquisition-ready"
                release = app.home / "acquisition-release"
                os.mkfifo(ready)
                os.mkfifo(release)
                descriptor = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
                self.addCleanup(os.close, descriptor)
                tools = app.home / "test-tools"
                tools.mkdir()
                wrapper = tools / "python3"
                wrapper.write_text(
                    f"#!{sys.executable}\n"
                    "import sys\n"
                    "script = sys.argv[2]\n"
                    "if 'def maintain(home)' in script:\n"
                    f"    with open({str(ready)!r}, 'w') as pipe:\n"
                    "        pipe.write('acquiring')\n"
                    f"    with open({str(release)!r}) as pipe:\n"
                    "        pipe.read(1)\n"
                    "sys.argv = ['-c', *sys.argv[3:]]\n"
                    "exec(compile(script, '<maintenance>', 'exec'))\n"
                )
                wrapper.chmod(0o700)
                cleanup = subprocess.Popen(
                    [
                        str(ROOT / "cli/bin/albedo"),
                        "storage",
                        "prune",
                        "--all",
                        "--yes",
                    ],
                    env=dict(app.env, PATH=str(tools) + os.pathsep + app.env["PATH"]),
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
                self.addCleanup(self.close_helper, cleanup)
                readable, _, _ = select.select([descriptor], [], [], 20)
                self.assertEqual(
                    readable, [descriptor], "cleanup never approved its preview"
                )
                self.assertEqual(os.read(descriptor, 1024), b"acquiring")
                # The CLI has previewed and approved storage, but has not claimed
                # ownership. Boot the runner's real daemon before releasing it.
                app.daemon.boot()
                with release.open("w") as pipe:
                    pipe.write("x")
                _, stderr = cleanup.communicate(timeout=20)
                self.assertNotEqual(cleanup.returncode, 0)
                self.assertIn(b"storage is in use", stderr)
                self.assertEqual(backup.read_bytes(), b"approved backup")
                self.close_helper(cleanup)

            app.restart(prepare=maintenance)

    @exclusive
    def test_successful_cleanup_retains_session_files_and_releases_ownership(self):
        with Albedo() as app:
            session = app.session()
            history = app.history(session)

            def maintenance(app):
                kernels = app.home / "kernels"
                kernels.mkdir(exist_ok=True)
                backups = app.home / "backups"
                backups.mkdir(exist_ok=True)
                live = kernels / f"{session}.state"
                old_orphan = kernels / "old-orphan.state"
                recent_orphan = kernels / "recent-orphan.state"
                old_backup = backups / "albedo-before-image-store-1.sqlite"
                recent_backup = backups / "albedo-before-image-store-2.sqlite"
                snapshot = pickle.dumps(
                    {"cwd": str(app.workspace), "names": {}, "definitions": []}
                )
                retained = {
                    live: snapshot,
                    recent_orphan: b"recent state",
                    recent_backup: b"recent backup",
                }
                for path, content in retained.items():
                    path.write_bytes(content)
                old_orphan.write_bytes(snapshot)
                old_backup.write_bytes(b"old backup")
                old = time.time() - 31 * 24 * 60 * 60
                for path in (live, old_orphan, old_backup):
                    os.utime(path, (old, old))

                with closing(sqlite3.connect(app.home / "albedo.sqlite")) as db:
                    db.execute("CREATE TABLE cleanup_reclaim(data BLOB)")
                    db.execute("INSERT INTO cleanup_reclaim VALUES(zeroblob(1048576))")
                    db.execute("DELETE FROM cleanup_reclaim")
                    db.commit()
                before = json.loads(app.cli("storage", "--json"))
                self.assertGreater(before["db"]["free_pages"], 0)

                app.cli("storage", "prune", "--all", "--yes")

                for path in (old_orphan, old_backup):
                    self.assertFalse(path.exists(), f"cleanup retained {path}")
                for path, content in retained.items():
                    self.assertEqual(path.read_bytes(), content)
                after = json.loads(app.cli("storage", "--json"))
                self.assertEqual(after["db"]["free_pages"], 0)
                self.assertLess(after["database"], before["database"])
                self.assertEqual(after["db"]["sessions"], before["db"]["sessions"])
                with closing(
                    sqlite3.connect(app.home / "daemon.lock", timeout=0)
                ) as db:
                    db.execute("BEGIN EXCLUSIVE")

            app.restart(prepare=maintenance)
            with app.api("/health") as response:
                self.assertEqual(response.status, 200)
            self.assertEqual(app.history(session), history)
