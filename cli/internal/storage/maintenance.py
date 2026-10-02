"""Own the daemon lock and perform only cleanup authorized over the input pipe."""

import json
import os
from pathlib import Path
import sqlite3
import stat
import sys
import threading


def identity(path):
    info = os.lstat(path)
    if not stat.S_ISREG(info.st_mode):
        raise RuntimeError(f"expected a regular file: {path}")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def watch_owner():
    # EOF means the CLI has gone away. Exit even if SQLite is busy in VACUUM.
    while os.read(sys.stdin.fileno(), 4096):
        pass
    os._exit(1)


def maintain(home):
    connection = sqlite3.connect(home / "daemon.lock", timeout=0)
    try:
        try:
            connection.execute("BEGIN EXCLUSIVE")
        except sqlite3.OperationalError as error:
            if error.sqlite_errorcode in (sqlite3.SQLITE_BUSY, sqlite3.SQLITE_LOCKED):
                raise RuntimeError(
                    "storage is in use by an Albedo daemon or maintenance command; "
                    "stop Albedo after its work finishes, or wait for maintenance, "
                    "then try again; no files have been removed"
                ) from error
            raise
        request = json.loads(sys.stdin.buffer.readline())
        paths = request["paths"]
        captured = [identity(path) for path in paths]
        print(json.dumps({"ready": True}), flush=True)
        authorization = sys.stdin.buffer.readline()
        if not authorization:
            return
        work = json.loads(authorization)
        if work["apply"] is not True:
            return
        threading.Thread(target=watch_owner, daemon=True).start()
        for path, approved in zip(paths, captured, strict=True):
            if identity(path) != approved:
                raise RuntimeError(
                    f"file changed after the preview; cleanup stopped: {path}"
                )
        for path in paths:
            os.unlink(path)
        result = {"VacuumSkipped": False, "Vacuumed": False, "Before": 0, "After": 0}
        if work["vacuum"]:
            if work["before"] == 0:
                raise RuntimeError("no SQLite database to shrink")
            if work["free_pages"] == 0:
                result["VacuumSkipped"] = True
            else:
                database = home / "albedo.sqlite"
                # mode=rw prevents a missing database from being recreated.
                db = sqlite3.connect(database.as_uri() + "?mode=rw", uri=True)
                try:
                    db.execute("VACUUM")
                finally:
                    db.close()
                result.update(
                    Vacuumed=True, Before=work["before"], After=identity(database)[2]
                )
        print(json.dumps({"result": result}), flush=True)
    finally:
        # Never commit this transaction or change the lock file's journal mode.
        connection.close()


if __name__ == "__main__":
    try:
        maintain(Path(sys.argv[1]).resolve())
    except Exception as error:
        print(str(error), file=sys.stderr, flush=True)
        sys.exit(1)
