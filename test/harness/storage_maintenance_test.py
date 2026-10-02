"""Catch orphaned cleanup workers with deterministic gates inside unlink and VACUUM.

The real CLI and daemon E2E tests cannot pause these Python calls. These tests
run the production helper, replacing only the operation's scheduling with an
acknowledged gate. EOF or death must stop that one process and release its lock.
"""

from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "cli/internal/storage/maintenance.py"

CONTROLLED_WORK = """
import json, runpy, sys, threading
module = runpy.run_path(sys.argv[1])
operation, home, candidate = sys.argv[2:]
def gate():
    print(json.dumps({'working': operation}), flush=True)
    threading.Event().wait()
if operation == 'delete':
    module['os'].unlink = lambda path: gate()
else:
    connect = module['sqlite3'].connect
    def controlled_connect(path, *args, **kwargs):
        db = connect(path, *args, **kwargs)
        if 'albedo.sqlite' in str(path):
            db.set_progress_handler(gate, 1)
        return db
    module['sqlite3'].connect = controlled_connect
module['maintain'](module['Path'](home))
"""

OWNER = """
import json, signal, subprocess, sys
helper = subprocess.Popen([sys.executable, sys.argv[1], sys.argv[2]],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
helper.stdin.write(json.dumps({'paths': []}) + '\\n')
helper.stdin.flush()
assert json.loads(helper.stdout.readline()) == {'ready': True}
print(helper.pid, flush=True)
signal.pause()
"""


class MaintenanceLifetimeTests(unittest.TestCase):
    def assert_released(self, home):
        with sqlite3.connect(home / "daemon.lock", timeout=0) as db:
            db.execute("BEGIN EXCLUSIVE")

    def assert_owned(self, home):
        with closing(sqlite3.connect(home / "daemon.lock", timeout=0)) as db:
            with self.assertRaises(sqlite3.OperationalError) as refused:
                db.execute("BEGIN EXCLUSIVE")
            self.assertIn(
                refused.exception.sqlite_errorcode,
                (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED),
            )

    def close_process(self, process):
        if process.poll() is None:
            process.kill()
        process.wait(timeout=10)
        for pipe in (process.stdin, process.stdout, process.stderr):
            if pipe and not pipe.closed:
                pipe.close()

    def test_death_or_eof_during_delete_and_vacuum_releases_ownership(self):
        for operation in ("delete", "vacuum"):
            for death in ("helper killed", "owner EOF"):
                with (
                    self.subTest(operation=operation, death=death),
                    tempfile.TemporaryDirectory() as directory,
                ):
                    home = Path(directory)
                    candidate = home / "candidate"
                    candidate.write_bytes(b"approved")
                    with sqlite3.connect(home / "albedo.sqlite") as db:
                        db.execute("CREATE TABLE reclaim(data BLOB)")
                        db.execute("INSERT INTO reclaim VALUES(zeroblob(262144))")
                        db.execute("DELETE FROM reclaim")
                    before = (home / "albedo.sqlite").read_bytes()
                    worker = subprocess.Popen(
                        [
                            sys.executable,
                            "-c",
                            CONTROLLED_WORK,
                            str(HELPER),
                            operation,
                            directory,
                            str(candidate),
                        ],
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    self.addCleanup(self.close_process, worker)
                    assert worker.stdin is not None and worker.stdout is not None
                    worker.stdin.write(json.dumps({"paths": [str(candidate)]}) + "\n")
                    worker.stdin.flush()
                    self.assertEqual(
                        json.loads(worker.stdout.readline()), {"ready": True}
                    )
                    worker.stdin.write(
                        json.dumps(
                            {
                                "apply": True,
                                "vacuum": operation == "vacuum",
                                "before": len(before),
                                "free_pages": 1,
                            }
                        )
                        + "\n"
                    )
                    worker.stdin.flush()
                    self.assertEqual(
                        json.loads(worker.stdout.readline()), {"working": operation}
                    )
                    self.assert_owned(home)
                    if death == "helper killed":
                        worker.kill()
                    else:
                        worker.stdin.close()
                    self.assertNotEqual(worker.wait(timeout=10), 0)
                    self.assert_released(home)
                    if operation == "delete":
                        self.assertEqual(candidate.read_bytes(), b"approved")
                    else:
                        self.assertFalse(candidate.exists())
                        self.assertEqual((home / "albedo.sqlite").read_bytes(), before)
                    self.close_process(worker)

    @unittest.skipUnless(hasattr(os, "pidfd_open"), "requires Linux pidfds")
    def test_owner_killed_before_authorization_releases_helper(self):
        import select

        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            owner = subprocess.Popen(
                [sys.executable, "-c", OWNER, str(HELPER), directory],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            self.addCleanup(self.close_process, owner)
            assert owner.stdout is not None
            helper_pid = int(owner.stdout.readline())
            descriptor = os.pidfd_open(helper_pid)
            try:
                owner.kill()
                owner.wait(timeout=10)
                readable, _, _ = select.select([descriptor], [], [], 10)
                self.assertEqual(readable, [descriptor], "helper survived its owner")
                self.assert_released(home)
            finally:
                os.close(descriptor)
            self.close_process(owner)


if __name__ == "__main__":
    unittest.main()
