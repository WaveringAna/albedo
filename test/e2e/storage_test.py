"""Offline cleanup and daemon startup must exclude each other, even without HTTP."""

from contextlib import closing
import hashlib
import json
import os
import pickle
import signal
import select
import sqlite3
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
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
            before = app.cli("storage", "--offline", "--json")
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
                unavailable = subprocess.run(
                    [str(ROOT / "cli/bin/albedo"), "storage", "--json"],
                    env=dict(app.env, ALBEDO_DAEMON="/nonexistent/no-launch"),
                    cwd=ROOT,
                    capture_output=True,
                    timeout=30,
                )
                self.assertNotEqual(unavailable.returncode, 0)
                self.assertEqual(unavailable.stdout, b"")
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
                self.assertEqual(backup.read_bytes(), b"approved backup")
                self.assertEqual(
                    json.loads(app.cli("storage", "--offline", "--json")),
                    json.loads(before),
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

    @exclusive
    def test_online_report_uses_daemon_storage_without_client_disk_or_python(self):
        with Albedo() as app:
            session = app.session()
            image_reference = b'{"image_hash":"storage-report-image"}'
            source = "é🐈"
            trace = b"trace"
            expected_session_bytes = (
                3 + len(image_reference) * 2 + len(source) + len(trace)
            )
            with closing(sqlite3.connect(app.home / "albedo.sqlite")) as db:
                db.execute("DELETE FROM transcript WHERE session=?", (session,))
                db.execute(
                    "INSERT INTO transcript(session,payload) VALUES(?,?)",
                    (session, image_reference),
                )
                if "pinned_context" in {
                    row[1] for row in db.execute("PRAGMA table_info(sessions)")
                }:
                    db.execute(
                        "UPDATE sessions SET pinned_context=? WHERE id=?",
                        ("pin", session),
                    )
                db.execute(
                    "INSERT INTO images(hash,data) VALUES(?,?)",
                    ("storage-report-image", b"imagebytes"),
                )
                db.execute(
                    "INSERT INTO cells(id,session,source,status,payload) VALUES(?,?,?,?,?)",
                    (
                        "storage-report-cell",
                        session,
                        source,
                        "finished",
                        image_reference,
                    ),
                )
                db.execute(
                    "INSERT INTO cell_traces(id,payload) VALUES(?,?)",
                    ("storage-report-cell", trace),
                )
                db.execute("CREATE TABLE report_reclaim(data BLOB)")
                db.execute("INSERT INTO report_reclaim VALUES(zeroblob(262144))")
                db.execute("DELETE FROM report_reclaim")
                db.commit()
            kernels = app.home / "kernels"
            kernels.mkdir(exist_ok=True)
            orphan = kernels / "report-orphan.state"
            live = kernels / f"{session}.state"
            orphan.write_bytes(b"orphan")
            live.write_bytes(b"live")
            backups = app.home / "backups"
            baseline_backups = (
                sum(path.stat().st_size for path in backups.iterdir() if path.is_file())
                if backups.exists()
                else 0
            )
            backup = self.backup(app)
            recent_backup = backup.parent / "albedo-before-image-store-2.sqlite"
            recent_backup.write_bytes(b"recent")
            unrelated_backup = backup.parent / "personal.sqlite"
            unrelated_backup.write_bytes(b"personal")
            old = time.time() - 31 * 24 * 60 * 60
            for path in (orphan, live):
                os.utime(path, (old, old))
            offline = json.loads(app.cli("storage", "--offline", "--json"))
            expected_other = sum(
                path.stat().st_size
                for path in app.home.iterdir()
                if path.is_file()
                and path.name
                not in {"albedo.sqlite", "albedo.sqlite-wal", "albedo.sqlite-shm"}
            )
            with tempfile.TemporaryDirectory() as directory:
                client_home = Path(directory)
                (client_home / "daemon.json").write_bytes(
                    (app.home / "daemon.json").read_bytes()
                )
                # These paths cannot be inspected as storage, and any attempted
                # diagnostic Python launch leaves an observable marker.
                (client_home / "albedo.sqlite").mkdir()
                (client_home / "kernels").write_bytes(b"not a directory")
                tools = client_home / "tools"
                tools.mkdir()
                marker = client_home / "python-called"
                python = tools / "python3"
                python.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 91\n")
                python.chmod(0o700)
                command = subprocess.run(
                    [str(ROOT / "cli/bin/albedo"), "storage", "--json"],
                    env=dict(
                        app.env,
                        ALBEDO_HOME=str(client_home),
                        PATH=str(tools) + os.pathsep + app.env["PATH"],
                    ),
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                self.assertEqual(command.returncode, 0, command.stderr)
                report = json.loads(command.stdout)
                self.assertEqual(
                    report["db"]["sessions"],
                    [{"id": session, "bytes": expected_session_bytes}],
                )
                self.assertEqual(report["db"]["images"], 10)
                self.assertEqual(
                    report["old_kernels"], [{"path": str(orphan), "bytes": 6}]
                )
                self.assertEqual(
                    report["old_backups"], [{"path": str(backup), "bytes": 15}]
                )
                self.assertEqual(report["kernels"], 10)
                self.assertEqual(report["backups"], baseline_backups + 29)
                self.assertEqual(report["recent_backups"], 6)
                self.assertEqual(report["recent_backup_count"], 1)
                self.assertEqual(report["other"], expected_other)
                self.assertGreater(report["db"]["free_pages"], 0)
                for key in (
                    "old_kernels",
                    "old_backups",
                    "kernels",
                    "backups",
                    "other",
                    "recent_backups",
                    "recent_backup_count",
                ):
                    self.assertEqual(report[key], offline[key], key)
                self.assertEqual(report["db"], offline["db"])
                self.assertGreater(report["database"], 0)
                self.assertGreater(report["db"]["page_size"], 0)
                self.assertFalse(
                    marker.exists(), "online reporting invoked client Python"
                )
                record = json.loads((client_home / "daemon.json").read_text())
                self.assertEqual(record, app.connection)

    @exclusive
    def test_offline_reports_supported_older_layouts_and_rejects_unknown_without_changes(
        self,
    ):
        with Albedo(providers={}) as app, tempfile.TemporaryDirectory() as directory:
            home = Path(directory) / "missing"

            def report(*options, path=None):
                return subprocess.run(
                    [str(ROOT / "cli/bin/albedo"), "storage", *options, "--json"],
                    env=dict(
                        app.env,
                        ALBEDO_HOME=str(home),
                        ALBEDO_DAEMON="/nonexistent/no-launch",
                        PATH=app.env["PATH"] if path is None else path,
                    ),
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )

            missing = report("--offline", path="")
            self.assertEqual(missing.returncode, 0, missing.stderr)
            empty = json.loads(missing.stdout)
            self.assertEqual(empty["db"]["sessions"], [])
            self.assertEqual(empty["old_kernels"], [])
            self.assertEqual(empty["old_backups"], [])
            self.assertFalse(home.exists())
            home.mkdir()
            # No record also selects offline automatically, without creating one.
            absent = report(path="")
            self.assertEqual(absent.returncode, 0, absent.stderr)
            self.assertEqual(json.loads(absent.stdout), empty)
            self.assertEqual(list(home.iterdir()), [])
            database = home / "albedo.sqlite"
            with closing(sqlite3.connect(database)) as db:
                db.executescript(
                    "CREATE TABLE sessions(id TEXT); CREATE TABLE transcript(session TEXT,payload BLOB); CREATE TABLE images(data TEXT);"
                )
                db.execute("INSERT INTO sessions VALUES(?)", ("older",))
                db.execute("INSERT INTO transcript VALUES(?,?)", ("older", b"history"))
                db.execute("INSERT INTO images VALUES(?)", ("é🐈",))
                db.commit()
            before = database.read_bytes()
            supported = report("--offline")
            self.assertEqual(supported.returncode, 0, supported.stderr)
            older = json.loads(supported.stdout)
            self.assertEqual(older["db"]["sessions"], [{"id": "older", "bytes": 7}])
            self.assertEqual(older["db"]["images"], 2)
            missing_python = report("--offline", path="")
            self.assertNotEqual(missing_python.returncode, 0)
            self.assertIn("require Python", missing_python.stderr)
            self.assertEqual(database.read_bytes(), before)
            self.assertEqual({path.name for path in home.iterdir()}, {"albedo.sqlite"})
            with closing(sqlite3.connect(database)) as db:
                db.execute(
                    "ALTER TABLE transcript RENAME COLUMN payload TO unknown_payload"
                )
                db.commit()
            kernels = home / "kernels"
            kernels.mkdir()
            candidate = kernels / "unproven.state"
            candidate.write_bytes(b"retain")
            old = time.time() - 31 * 24 * 60 * 60
            os.utime(candidate, (old, old))
            before = database.read_bytes()
            unsupported = report("--offline")
            self.assertNotEqual(unsupported.returncode, 0)
            self.assertIn("unsupported storage layout", unsupported.stderr)
            self.assertEqual(unsupported.stdout, "")
            self.assertEqual(database.read_bytes(), before)
            self.assertEqual(candidate.read_bytes(), b"retain")
            self.assertFalse((home / "daemon.json").exists())
            source = Path(directory) / "wal-source.sqlite"
            with closing(sqlite3.connect(source)) as writer:
                writer.execute("PRAGMA journal_mode=WAL")
                writer.executescript(
                    "CREATE TABLE sessions(id TEXT); CREATE TABLE transcript(session TEXT,payload BLOB);"
                )
                writer.execute("INSERT INTO sessions VALUES('wal-session')")
                writer.execute(
                    "INSERT INTO transcript VALUES('wal-session',?)",
                    (b"committed in WAL",),
                )
                writer.commit()
                home = Path(directory) / "wal-home"
                home.mkdir()
                (home / "albedo.sqlite").write_bytes(source.read_bytes())
                (home / "albedo.sqlite-wal").write_bytes(
                    Path(str(source) + "-wal").read_bytes()
                )
            originals = {path.name: path.read_bytes() for path in home.iterdir()}
            self.assertNotIn("albedo.sqlite-shm", originals)
            wal_report = report("--offline")
            self.assertEqual(wal_report.returncode, 0, wal_report.stderr)
            self.assertEqual(
                json.loads(wal_report.stdout)["db"]["sessions"],
                [{"id": "wal-session", "bytes": 16}],
            )
            self.assertEqual(
                {path.name: path.read_bytes() for path in home.iterdir()}, originals
            )

    @exclusive
    def test_report_mode_selection_never_launches_or_hides_discovery_and_auth_failures(
        self,
    ):
        with Albedo(providers={}) as app, tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            record = home / "daemon.json"

            def report(*options):
                return subprocess.run(
                    [str(ROOT / "cli/bin/albedo"), "storage", *options, "--json"],
                    env=dict(
                        app.env,
                        ALBEDO_HOME=str(home),
                        ALBEDO_DAEMON="/nonexistent/no-launch",
                    ),
                    cwd=ROOT,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )

            absent = report()
            self.assertEqual(absent.returncode, 0, absent.stderr)
            empty = json.loads(absent.stdout)
            self.assertEqual(list(home.iterdir()), [])
            with socket.socket() as endpoint:
                endpoint.bind(("127.0.0.1", 0))
                refused_port = endpoint.getsockname()[1]
            stale = dict(app.connection, pid=2147483647, port=refused_port)
            record.write_text(json.dumps(stale))
            stale_bytes = record.read_bytes()
            stale_result = report()
            self.assertEqual(stale_result.returncode, 0, stale_result.stderr)
            self.assertEqual(
                json.loads(stale_result.stdout), dict(empty, other=len(stale_bytes))
            )
            self.assertEqual(record.read_bytes(), stale_bytes)
            for content in (
                "not JSON",
                json.dumps(dict(app.connection, token="wrong-token")),
            ):
                with self.subTest(record=content):
                    record.write_text(content)
                    failed = report()
                    self.assertNotEqual(failed.returncode, 0)
                    self.assertEqual(failed.stdout, "")
                    self.assertEqual(record.read_text(), content)
                    explicit = report("--offline")
                    self.assertEqual(explicit.returncode, 0, explicit.stderr)
                    # The discovery record itself is a regular local file.
                    local = json.loads(explicit.stdout)
                    self.assertEqual(local["other"], len(content.encode()))
                    self.assertEqual(local["db"]["sessions"], [])
                    self.assertEqual(record.read_text(), content)
                    self.assertEqual(
                        {path.name for path in home.iterdir()}, {"daemon.json"}
                    )

    @exclusive
    @unittest.skipUnless(hasattr(os, "pidfd_open"), "requires Linux pidfds")
    def test_canceling_offline_diagnostic_reaps_child_and_removes_private_snapshot(
        self,
    ):
        with Albedo(providers={}) as app, tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home = root / "home"
            home.mkdir()
            database = home / "albedo.sqlite"
            with closing(sqlite3.connect(database)) as db:
                db.executescript(
                    "CREATE TABLE sessions(id TEXT); CREATE TABLE transcript(session TEXT,payload BLOB);"
                )
                db.commit()
            before = database.read_bytes()
            scratch = root / "scratch"
            scratch.mkdir()
            ready = root / "ready"
            os.mkfifo(ready)
            descriptor = os.open(ready, os.O_RDWR | os.O_NONBLOCK)
            self.addCleanup(os.close, descriptor)
            tools = root / "tools"
            tools.mkdir()
            python = tools / "python3"
            python.write_text(
                f"#!{sys.executable}\n"
                "import os, sys, threading\n"
                "from pathlib import Path\n"
                "snapshot = Path(sys.argv[4])\n"
                "(snapshot / 'albedo.sqlite').write_bytes(b'partial snapshot')\n"
                f"with open({str(ready)!r}, 'w') as pipe:\n"
                "    pipe.write(str(os.getpid()) + '\\n')\n"
                "threading.Event().wait()\n"
            )
            python.chmod(0o700)
            for death in (signal.SIGINT, signal.SIGTERM):
                with self.subTest(signal=death):
                    command = subprocess.Popen(
                        [
                            str(ROOT / "cli/bin/albedo"),
                            "storage",
                            "--offline",
                            "--json",
                        ],
                        env=dict(
                            app.env,
                            ALBEDO_HOME=str(home),
                            TMPDIR=str(scratch),
                            PATH=str(tools) + os.pathsep + app.env["PATH"],
                        ),
                        cwd=ROOT,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    self.addCleanup(self.close_helper, command)
                    readable, _, _ = select.select([descriptor], [], [], 20)
                    self.assertEqual(
                        readable,
                        [descriptor],
                        "diagnostic never created its private snapshot",
                    )
                    child = int(os.read(descriptor, 1024))
                    child_descriptor = os.pidfd_open(child)
                    try:
                        self.assertEqual(len(list(scratch.iterdir())), 1)
                        command.send_signal(death)
                        stdout, _ = command.communicate(timeout=10)
                        self.assertNotEqual(command.returncode, 0)
                        self.assertEqual(stdout, b"")
                        readable, _, _ = select.select([child_descriptor], [], [], 10)
                        self.assertEqual(
                            readable,
                            [child_descriptor],
                            "diagnostic child survived cancellation",
                        )
                        self.assertEqual(
                            list(scratch.iterdir()),
                            [],
                            "private snapshot leaked after cancellation",
                        )
                        self.assertEqual(database.read_bytes(), before)
                        self.assertEqual(
                            {path.name for path in home.iterdir()}, {"albedo.sqlite"}
                        )
                    finally:
                        os.close(child_descriptor)
                        self.close_helper(command)
