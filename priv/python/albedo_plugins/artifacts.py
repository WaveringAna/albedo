"""Artifacts: web pages the agent makes, from one HTML file to a built app.

Each save uploads only the files the daemon does not have yet (by SHA-256),
then records the version as a manifest of path, hash and size. See
robot-docs/artifacts.md.
"""

from __future__ import annotations

import asyncio
import base64
import builtins
import hashlib
import json
import os
import re
from typing import cast

import albedo_trace
from albedo_api import Host, PythonApi, Record

host: Host

FILE_LIMIT = 16 * 1024 * 1024
VERSION_LIMIT = 64 * 1024 * 1024
SKIPPED = {".git", ".DS_Store", "node_modules", "__pycache__"}
# A built page that loads its own files from the server root ("/assets/...")
# would reach albedo web's own files instead of the artifact's.
ROOTED = re.compile(r"""(?:src|href)\s*=\s*["']/(?![/])""", re.I)


class Artifact(Record):
    """One artifact at one version: artifact.id and artifact["id"] both work."""

    id: str
    title: str
    version: int
    versions: int
    entry: str
    session: str
    workspace: str
    created_at: int
    updated_at: int
    bytes: int


Files = dict[str, "str | bytes | None"]


def _encoded(value: str | bytes) -> bytes:
    if isinstance(value, str):
        return value.encode("utf-8")
    if isinstance(value, (bytes, bytearray, memoryview)):
        return bytes(value)
    raise TypeError(f"a file is str or bytes, not {type(value).__name__}")


def _walk(directory: str) -> dict[str, bytes]:
    root = os.path.abspath(os.path.expanduser(directory))
    if not os.path.isdir(root):
        raise FileNotFoundError(f"no such directory: {directory}")
    found: dict[str, bytes] = {}
    total = 0
    for folder, folders, names in os.walk(root):
        folders[:] = sorted(name for name in folders if name not in SKIPPED)
        for name in sorted(names):
            if name in SKIPPED:
                continue
            path = os.path.join(folder, name)
            relative = os.path.relpath(path, root).replace(os.sep, "/")
            size = os.path.getsize(path)
            if size > FILE_LIMIT:
                raise ValueError(f"{relative} is larger than 16 MiB")
            total += size
            if total > VERSION_LIMIT:
                raise ValueError(f"{directory} holds more than 64 MiB")
            with open(path, "rb") as file:
                found[relative] = file.read()
    if not found:
        raise ValueError(f"{directory} is empty")
    return found


def _rooted(files: dict[str, bytes]) -> builtins.list[str]:
    return [
        path
        for path, data in files.items()
        if path.lower().endswith((".html", ".htm"))
        and ROOTED.search(data.decode("utf-8", "replace"))
    ]


async def _upload(files: dict[str, bytes]) -> builtins.list[dict[str, object]]:
    manifest: builtins.list[dict[str, object]] = [
        {"path": path, "hash": hashlib.sha256(data).hexdigest(), "size": len(data)}
        for path, data in files.items()
    ]
    by_hash = {entry["hash"]: files[cast(str, entry["path"])] for entry in manifest}
    missing = cast(
        builtins.list[str],
        await host("artifacts.missing", {"hashes": builtins.list(by_hash)}),
    )
    gate = asyncio.Semaphore(4)

    async def send(digest: str) -> None:
        async with gate:
            data = base64.b64encode(by_hash[digest]).decode("ascii")
            await host("artifacts.upload", {"hash": digest, "data": data})

    await asyncio.gather(*(send(digest) for digest in missing))
    return manifest


def _one_source(html: object, files: object, directory: object) -> None:
    given = [
        name
        for name, value in (("html", html), ("files", files), ("directory", directory))
        if value is not None
    ]
    if len(given) > 1:
        raise ValueError(
            f"give one of html, files or directory, not {' and '.join(given)}"
        )


def _cell() -> str | None:
    capture = albedo_trace.current()
    return cast("str | None", getattr(capture, "id", None))


async def _save(arguments: dict[str, object]) -> Artifact:
    saved = cast(dict, await host("artifacts.save", {**arguments, "cell": _cell()}))
    artifact = Artifact(saved["artifact"])
    albedo_trace.artifact(artifact.id, artifact.version, artifact.title)
    return artifact


class Artifacts:
    async def create(
        self,
        title: str,
        html: str | None = None,
        *,
        files: Files | None = None,
        directory: str | None = None,
        entry: str = "index.html",
    ) -> Artifact:
        """Make an artifact from one page (html), several files (files=
        {path: str | bytes}) or a built app (directory=). It opens beside
        the chat."""
        _one_source(html, files, directory)
        if html is not None:
            tree = {entry: _encoded(html)}
        elif files is not None:
            tree = {
                path: _encoded(value)
                for path, value in files.items()
                if value is not None
            }
        elif directory is not None:
            tree = _walk(directory)
        else:
            raise ValueError("give the page: create(title, html), files= or directory=")
        self._check(tree, entry)
        manifest = await _upload(tree)
        return await _save({"title": title, "entry": entry, "files": manifest})

    async def update(
        self,
        id: str,
        html: str | None = None,
        *,
        files: Files | None = None,
        directory: str | None = None,
        entry: str | None = None,
        title: str | None = None,
    ) -> Artifact:
        """Write the next version. html replaces the entry page; files=
        changes only the paths it names (None removes one); directory=
        replaces the whole tree. With only title= it renames."""
        _one_source(html, files, directory)
        if html is None and files is None and directory is None:
            if title is None:
                raise ValueError(
                    "give the next version (html, files= or directory=) or a new title"
                )
            return await _save({"id": id, "title": title})
        if directory is not None:
            tree = _walk(directory)
            self._check(tree, entry or "index.html")
            manifest = await _upload(tree)
            return await _save(
                {"id": id, "title": title, "entry": entry, "files": manifest}
            )
        current = cast(dict, await host("artifacts.manifest", {"id": id}))
        kept = {item["path"]: item for item in current["files"]}
        changed: dict[str, bytes] = {}
        if html is not None:
            changed[entry or current["entry"]] = _encoded(html)
        for path, value in (files or {}).items():
            if value is None:
                if kept.pop(path, None) is None:
                    raise ValueError(f"{path} is not a file of {id}")
            else:
                changed[path] = _encoded(value)
        self._check(changed, None)
        for item in await _upload(changed):
            kept[cast(str, item["path"])] = item
        return await _save(
            {
                "id": id,
                "title": title,
                "entry": entry,
                "files": builtins.list(kept.values()),
            }
        )

    def _check(self, tree: dict[str, bytes], entry: str | None) -> None:
        if entry is not None and entry not in tree:
            raise ValueError(
                f"the entry page {entry} is not among the files ({', '.join(sorted(tree)[:8])})"
            )
        rooted = _rooted(tree)
        if rooted:
            raise ValueError(
                f'{rooted[0]} loads files from the server root (src="/..."), which an artifact cannot serve;'
                " use relative paths (vite: build --base ./, or base: './' in vite.config)"
            )

    async def list(
        self, limit: int = 20, session: str | None = None
    ) -> builtins.list[Artifact]:
        """Artifacts newest change first; session="current" keeps this session's."""
        if session not in (None, "current"):
            raise ValueError('session is None (every session) or "current"')
        items = await host(
            "artifacts.list", {"limit": limit, "current": session == "current"}
        )
        return [Artifact(item) for item in cast(builtins.list[dict], items)]

    async def get(self, id: str, version: int | None = None) -> Artifact:
        """One version (the latest by default), with files as {path: size}."""
        return Artifact(
            cast(dict, await host("artifacts.get", {"id": id, "version": version}))
        )

    async def read(
        self, id: str, path: str | None = None, version: int | None = None
    ) -> str | bytes:
        """One file of a version, the entry page by default: str for text, bytes otherwise."""
        reply = cast(
            dict,
            await host("artifacts.read", {"id": id, "path": path, "version": version}),
        )
        data = base64.b64decode(reply["data"])
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data

    async def state(self, id: str) -> dict[str, str]:
        """What the page saved in its localStorage."""
        reply = cast(dict, await host("artifacts.state", {"id": id}))
        return cast(dict[str, str], json.loads(reply["state"]))

    async def errors(self, id: str) -> builtins.list[Record]:
        """What failed in the page, oldest first (the newest 20 are kept)."""
        return [
            Record(item)
            for item in cast(
                builtins.list[dict], await host("artifacts.errors", {"id": id})
            )
        ]

    async def url(self, id: str, version: int | None = None) -> str:
        """The page's address on the running albedo web, for the browser plugin."""
        reply = cast(
            dict, await host("artifacts.frame", {"id": id, "version": version})
        )
        home = os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo")
        try:
            with open(os.path.join(home, "web.json")) as file:
                web = json.load(file)
            os.kill(int(web["pid"]), 0)
        except (OSError, ValueError, KeyError, TypeError):
            raise RuntimeError(
                'albedo web is not running; start it with run("albedo", "web", "--no-open", service=True)'
            ) from None
        return str(web["url"]).rstrip("/") + reply["path"]


artifacts = Artifacts()


def setup(api: PythonApi) -> dict[str, object]:
    global host
    host = api.host
    return {"artifacts": artifacts, "ArtifactError": api.HostError}
