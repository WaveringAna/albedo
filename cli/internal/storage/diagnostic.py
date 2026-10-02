"""Read known storage layouts without creating, migrating, or modifying SQLite."""

from contextlib import closing

import json
import sqlite3
import shutil
import stat
import sys
from pathlib import Path


def columns(db, table, required):
    found = {row[1] for row in db.execute(f"PRAGMA table_info({table})")}
    if not required <= found:
        missing = ", ".join(sorted(required - found))
        raise ValueError(
            f"unsupported storage layout: {table} lacks {missing}; "
            "use a compatible daemon to inspect or upgrade this database"
        )
    return found


def source_identity(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError(f"offline storage snapshot requires a regular file: {path}")
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def inspect(path, directory):
    sources = [path, Path(str(path) + "-wal")]
    before = [source_identity(source) for source in sources]
    if before[0] is None:
        raise ValueError(
            "database disappeared before offline inspection; retry the report"
        )
    # SQLite may create SHM while reading WAL, even in read-only mode. Keep that
    # side effect in a private snapshot and never build an index beside the source.
    snapshot = Path(directory) / "albedo.sqlite"
    for source, identity, target in zip(
        sources, before, [snapshot, Path(str(snapshot) + "-wal")]
    ):
        if identity is not None:
            shutil.copyfile(source, target)
    if [source_identity(source) for source in sources] != before:
        raise ValueError(
            "storage changed while copying the offline snapshot; retry the report or query the running daemon"
        )
    with closing(sqlite3.connect(snapshot.as_uri() + "?mode=ro", uri=True)) as db:
        db.execute("PRAGMA query_only=ON")
        tables = {
            row[0]
            for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")
        }
        # Existing databases must identify sessions and their durable transcript.
        session_columns = columns(db, "sessions", {"id"})
        columns(db, "transcript", {"session", "payload"})
        # This projection supports pre-pinned sessions and both TEXT and BLOB
        # image rows; startup migration markers need not be applied or rewritten.
        pinned = (
            "COALESCE(length(pinned_context),0)"
            if "pinned_context" in session_columns
            else "0"
        )
        sessions = [
            {"id": session_id, "bytes": size}
            for session_id, size in db.execute(
                f"SELECT id, {pinned} FROM sessions ORDER BY id"
            )
        ]
        identities = [session["id"] for session in sessions]
        if any(
            not isinstance(identity, str) or not identity for identity in identities
        ):
            raise ValueError(
                "unsupported storage layout: invalid session identity; use a compatible daemon to inspect this database"
            )
        if len(set(identities)) != len(identities):
            raise ValueError(
                "unsupported storage layout: duplicate session identities; use a compatible daemon to inspect this database"
            )
        sizes = dict(
            db.execute(
                "SELECT session, COALESCE(sum(length(payload)),0) "
                "FROM transcript GROUP BY session"
            )
        )
        for session in sessions:
            session["bytes"] += sizes.get(session["id"], 0)
        if "cell_traces" in tables:
            columns(db, "cell_traces", {"id", "payload"})
        if "cells" in tables:
            columns(db, "cells", {"id", "session", "source", "payload"})
            traces = (
                "LEFT JOIN cell_traces t ON t.id=c.id"
                if "cell_traces" in tables
                else ""
            )
            trace_bytes = "COALESCE(length(t.payload),0)" if traces else "0"
            sizes = dict(
                db.execute(
                    "SELECT c.session, COALESCE(sum(length(c.source) + "
                    "COALESCE(length(c.payload),0) + "
                    + trace_bytes
                    + "),0) FROM cells c "
                    + traces
                    + " GROUP BY c.session"
                )
            )
            for session in sessions:
                session["bytes"] += sizes.get(session["id"], 0)
        images = 0
        if "images" in tables:
            columns(db, "images", {"data"})
            images = db.execute(
                "SELECT COALESCE(sum(length(data)),0) FROM images"
            ).fetchone()[0]
        return {
            "sessions": sessions,
            "images": images,
            "free_pages": db.execute("PRAGMA freelist_count").fetchone()[0],
            "page_size": db.execute("PRAGMA page_size").fetchone()[0],
        }


if __name__ == "__main__":
    try:
        print(json.dumps(inspect(Path(sys.argv[1]), sys.argv[2])))
    except (sqlite3.Error, ValueError, OSError) as error:
        sys.exit(str(error))
