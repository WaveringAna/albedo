"""Project-scoped Markdown memory with literal and full-text recall."""

from __future__ import annotations

from contextlib import contextmanager
from datetime import date
import fcntl
import os
from pathlib import Path
import re
import sqlite3
import tempfile
from typing import Iterator

from albedo_api import PythonApi, Text
from albedo_plugins.files import Rows


class Memory:
    def __init__(self, root: Path) -> None:
        self.root = root

    @property
    def path(self) -> Path:
        return self.root / "memory.md"

    def read(self, max_chars: int = 16000) -> Text:
        if not 0 < max_chars <= 200_000:
            raise ValueError("0 < max_chars <= 200000")
        content = self.path.read_text() if self.path.exists() else ""
        suffix = (
            "\n[truncated; raise max_chars to read more]"
            if len(content) > max_chars
            else ""
        )
        return Text(content[:max_chars] + suffix)

    @contextmanager
    def _locked(self) -> Iterator[None]:
        self.root.mkdir(parents=True, exist_ok=True)
        with (self.root / ".lock").open("a+b") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def save(self, text: str) -> Text:
        """Atomically replace curated memory, serializing with append."""
        if len(text.encode("utf-8")) > 1_048_576:
            raise ValueError("memory.md cannot exceed 1 MiB")
        with self._locked():
            fd, name = tempfile.mkstemp(dir=self.root, prefix=".memory-")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as file:
                    file.write(text)
                os.replace(name, self.path)
            finally:
                if os.path.exists(name):
                    os.unlink(name)
        return Text(str(self.path))

    def append(self, text: str) -> Text:
        with self._locked():
            size = self.path.stat().st_size if self.path.exists() else 0
            extra = len(text.rstrip("\n").encode("utf-8")) + 1 + (size > 0)
            if size + extra > 1_048_576:
                raise ValueError("memory.md cannot exceed 1 MiB")
            self._append(self.path, text)
        return Text(str(self.path))

    def journal(self, text: str) -> Text:
        target = self.root / "journal" / f"{date.today().isoformat()}.md"
        with self._locked():
            target.parent.mkdir(exist_ok=True)
            self._append(target, text)
        return Text(str(target))

    @staticmethod
    def _append(path: Path, text: str) -> None:
        with path.open("a", encoding="utf-8") as file:
            if path.stat().st_size:
                file.write("\n")
            file.write(text.rstrip("\n") + "\n")

    def _documents(self) -> list[Path]:
        paths = [self.path, *sorted((self.root / "journal").glob("*.md"))]
        return [path for path in paths if path.is_file()]

    def grep(self, term: str, limit: int = 20) -> Rows:
        if not term or not 1 <= limit <= 100:
            raise ValueError("term must be nonempty and 1 <= limit <= 100")
        matches = []
        for path in self._documents():
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if term.casefold() in line.casefold():
                    matches.append(
                        f"{path.relative_to(self.root)}:{number}: {line[:500]}"
                    )
                    if len(matches) == limit:
                        return Rows(matches, truncated=True)
        return Rows(matches)

    def search(self, query: str, limit: int = 20) -> Rows:
        """FTS5 ranks paragraphs, including multiline entries, without a stale index."""
        if not query.strip() or not 1 <= limit <= 100:
            raise ValueError("query must be nonempty and 1 <= limit <= 100")
        with sqlite3.connect(":memory:") as db:
            db.execute(
                "CREATE VIRTUAL TABLE notes USING fts5(path UNINDEXED, line UNINDEXED, body)"
            )
            for path in self._documents():
                content = path.read_text()
                for match in re.finditer(
                    r"(?s)\S.*?(?=\n[ \t]*\n|\s*\Z)", content, re.S
                ):
                    line = content.count("\n", 0, match.start()) + 1
                    db.execute(
                        "INSERT INTO notes VALUES (?, ?, ?)",
                        (
                            str(path.relative_to(self.root)),
                            line,
                            match.group()[:100_000],
                        ),
                    )
            try:
                rows = db.execute(
                    "SELECT path, line, snippet(notes, 2, '[', ']', '…', 16) "
                    "FROM notes WHERE notes MATCH ? ORDER BY rank LIMIT ?",
                    (query, limit),
                ).fetchall()
            except sqlite3.OperationalError as exc:
                raise ValueError(f"invalid full-text query: {exc}") from exc
        return Rows(
            f"{path}:{line}: {snippet.replace(chr(10), ' ')[:500]}"
            for path, line, snippet in rows
        )


async def setup(api: PythonApi) -> dict[str, object]:
    workspace = await api.host("session.cwd", {})
    if not isinstance(workspace, str):
        raise ValueError("session.cwd did not return a workspace path")
    home = Path(os.environ.get("ALBEDO_HOME") or Path.home() / ".albedo")
    slug = re.sub(r"[^A-Za-z0-9]", "-", workspace)
    return {"memory": Memory(home / "memories" / slug)}
