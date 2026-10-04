"""Project-scoped Markdown memory with literal and full-text recall.

The files live on the daemon's machine, wherever this kernel runs, and every
call goes through the memory host route. Reads of a linked workspace's memory
come back with it; writes always land in this workspace's own.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import date
import re
from typing import cast

from albedo_api import PythonApi, Text
from albedo_plugins.files import Rows


class Memory:
    def __init__(self, host: Callable[[str, dict[str, object]], object]) -> None:
        self._host = host

    def read(self, max_chars: int = 16000) -> Text:
        if not 0 < max_chars <= 200_000:
            raise ValueError("0 < max_chars <= 200000")
        content = cast(str, self._host("memory.read", {}))
        suffix = (
            "\n[truncated; raise max_chars to read more]"
            if len(content) > max_chars
            else ""
        )
        return Text(content[:max_chars] + suffix)

    def save(self, text: str) -> Text:
        """Atomically replace curated memory."""
        return Text(cast(str, self._host("memory.save", {"text": text})))

    def append(self, text: str) -> Text:
        return Text(cast(str, self._host("memory.append", {"text": text})))

    def journal(self, text: str) -> Text:
        day = date.today().isoformat()
        return Text(
            cast(str, self._host("memory.journal", {"date": day, "text": text}))
        )

    def _documents(self) -> tuple[list[tuple[str, str]], bool]:
        """(name, text) for every memory and journal file this workspace
        reads; a linked workspace's names lead with it."""
        answer = cast(dict, self._host("memory.documents", {}))
        named = [
            (
                document["path"]
                if document["workspace"] == answer["own"]
                else f"[{document['workspace']}] {document['path']}",
                document["text"],
            )
            for document in answer["documents"]
        ]
        return named, bool(answer["truncated"])

    def grep(self, term: str, limit: int = 20) -> Rows:
        if not term or not 1 <= limit <= 100:
            raise ValueError("term must be nonempty and 1 <= limit <= 100")
        documents, cut = self._documents()
        matches = []
        for name, content in documents:
            for number, line in enumerate(content.splitlines(), 1):
                if term.casefold() in line.casefold():
                    matches.append(f"{name}:{number}: {line[:500]}")
                    if len(matches) == limit:
                        return Rows(matches, truncated=True)
        return Rows(matches, truncated=cut)

    def search(self, query: str, limit: int = 20) -> Rows:
        """FTS5 ranks paragraphs, including multiline entries, without a stale index."""
        if not query.strip() or not 1 <= limit <= 100:
            raise ValueError("query must be nonempty and 1 <= limit <= 100")
        import sqlite3  # only search needs it; not worth every kernel's boot

        documents, cut = self._documents()
        with sqlite3.connect(":memory:") as db:
            db.execute(
                "CREATE VIRTUAL TABLE notes USING fts5(path UNINDEXED, line UNINDEXED, body)"
            )
            for name, content in documents:
                for match in re.finditer(
                    r"(?s)\S.*?(?=\n[ \t]*\n|\s*\Z)", content, re.S
                ):
                    line = content.count("\n", 0, match.start()) + 1
                    db.execute(
                        "INSERT INTO notes VALUES (?, ?, ?)",
                        (name, line, match.group()[:100_000]),
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
            (
                f"{path}:{line}: {snippet.replace(chr(10), ' ')[:500]}"
                for path, line, snippet in rows
            ),
            truncated=cut,
        )


def setup(api: PythonApi) -> dict[str, object]:
    if api.host_now is None:
        raise RuntimeError("this host cannot answer synchronous memory calls")
    return {"memory": Memory(api.host_now)}
