"""Bounded, atomic snapshots of the kernel-owned namespace and definitions."""

from __future__ import annotations

import importlib
import os
import pickle
import sys
import tempfile
import types
from typing import Any, cast

# Saved state is the session's own namespace, written by this kernel into the
# daemon's home. Loading pickle and replaying definitions share the transcript's trust domain.
STATE_MAX = 64 * 1024 * 1024
STATE_MAX_VALUE = 8 * 1024 * 1024
DEFINITION_MAX = 256 * 1024
DEFINITION_MAX_VALUE = 32 * 1024
# What the kernel started with; entries a cell adds (a sys.path.insert before
# an import) are saved so replayed imports find their modules again.
START_PATH = list(sys.path)


def engine() -> tuple[object, str]:
    """dill when it is installed; pickle keeps plain data working without it."""
    try:
        import dill

        dill.settings["recurse"] = True
        return dill, "dill"
    except ImportError:
        return pickle, "pickle"


class TooLarge(Exception):
    """The value's serialisation passed the per-variable cap."""


class _Bounded:
    """A write sink that stops a serialiser once it has produced more than
    `limit` bytes, so an oversized value costs the cap, not its full size."""

    def __init__(self, limit: int) -> None:
        self.limit = limit
        self.chunks: list[bytes] = []
        self.size = 0

    def write(self, data: bytes) -> int:
        self.size += len(data)
        if self.size > self.limit:
            raise TooLarge
        self.chunks.append(bytes(data))
        return len(data)

    def getvalue(self) -> bytes:
        return b"".join(self.chunks)


def dumps_within(serialiser: Any, value: object, limit: int) -> bytes:
    """`serialiser.dumps(value)`, or TooLarge once it passes `limit` bytes."""
    sink = _Bounded(limit)
    serialiser.dump(value, sink)
    return sink.getvalue()


def save_state(
    path: str,
    namespace: dict[str, object],
    definitions: dict[str, str],
    injected: set[str],
) -> dict[str, object]:
    """Serialise values and readable top-level definitions within fixed caps."""
    serialiser, kind = cast("Any", engine())
    payload: dict[str, bytes] = {}
    modules: dict[str, str] = {}
    skipped: list[dict[str, str]] = []
    total = 0
    largest: list[tuple[str, int]] = []
    for name in list(namespace.keys()):
        if name.startswith("_") or name in injected:
            continue
        value = namespace.get(name, injected)
        if value is injected:
            continue
        if isinstance(value, types.ModuleType):
            # A module cannot be pickled; its import name is enough to bind it again.
            modules[name] = value.__name__
            continue
        replayed = name in definitions and isinstance(
            value, (types.FunctionType, type, types.ModuleType)
        )
        try:
            blob = dumps_within(serialiser, value, STATE_MAX_VALUE)
        except BaseException as error:
            reason = (
                f"over the {STATE_MAX_VALUE}-byte per-variable cap"
                if isinstance(error, TooLarge)
                else f"{type(error).__name__}: {error}"[:200]
            )
            if not replayed:
                skipped.append({"name": name, "reason": reason})
            continue
        if total + len(blob) > STATE_MAX:
            skipped.append({"name": name, "reason": "saved state is full"})
        else:
            payload[name] = blob
            total += len(blob)
            if len(blob) >= 64 * 1024:
                largest.append((name, len(blob)))
    saved_definitions: list[dict[str, str]] = []
    definition_bytes = 0
    for name, source in definitions.items():
        size = len(source.encode("utf-8"))
        if size > DEFINITION_MAX_VALUE:
            skipped.append(
                {
                    "name": name,
                    "reason": f"definition is {size} bytes; per-definition cap is {DEFINITION_MAX_VALUE}",
                }
            )
        elif definition_bytes + size > DEFINITION_MAX:
            skipped.append(
                {"name": name, "reason": "definitions are over the total source cap"}
            )
        else:
            saved_definitions.append({"name": name, "source": source})
            definition_bytes += size
    try:
        os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
        handle, temporary = tempfile.mkstemp(
            dir=os.path.dirname(path) or ".", prefix=os.path.basename(path) + "."
        )
        try:
            with os.fdopen(handle, "wb") as file:
                pickle.dump(
                    {
                        "cwd": os.getcwd(),
                        "path": [
                            entry
                            for entry in sys.path
                            if isinstance(entry, str) and entry not in START_PATH
                        ],
                        "modules": modules,
                        "names": payload,
                        "definitions": saved_definitions,
                    },
                    file,
                )
            os.replace(temporary, path)
        except BaseException:
            os.unlink(temporary)
            raise
    except OSError as error:
        return {"error": f"could not write saved state: {error}"}
    largest.sort(key=lambda item: item[1], reverse=True)
    return {
        "saved": sorted(
            set(payload) | set(modules) | {item["name"] for item in saved_definitions}
        ),
        "defs": [item["name"] for item in saved_definitions],
        "skipped": skipped,
        "largest": [{"name": name, "bytes": size} for name, size in largest[:5]],
        "bytes": total,
        "engine": kind,
    }


def load_state(
    path: str, namespace: dict[str, object], definitions: dict[str, str]
) -> dict[str, object]:
    """Restore the added sys.path entries and modules, then pickled values, then
    replay definitions in their saved order."""
    try:
        with open(path, "rb") as file:
            saved = cast(dict[str, object], pickle.load(file))
    except FileNotFoundError:
        return {"restored": [], "defs": [], "failed": [], "error": "no saved state"}
    except BaseException as error:
        return {
            "restored": [],
            "defs": [],
            "failed": [],
            "error": f"unreadable saved state: {type(error).__name__}",
        }
    serialiser, kind = cast("Any", engine())
    restored: list[str] = []
    failed: list[dict[str, str]] = []
    for entry in reversed(cast(list[object], saved.get("path", []))):
        if isinstance(entry, str) and entry not in sys.path:
            sys.path.insert(0, entry)
    for name, module in cast(dict[str, str], saved.get("modules", {})).items():
        try:
            namespace[name] = importlib.import_module(module)
        except BaseException as error:
            failed.append(
                {"name": name, "reason": f"{type(error).__name__}: {error}"[:200]}
            )
        else:
            restored.append(name)
    for name, blob in cast(dict[str, bytes], saved.get("names", {})).items():
        try:
            namespace[name] = cast(object, serialiser.loads(blob))
        except BaseException as error:
            failed.append(
                {"name": name, "reason": f"{type(error).__name__}: {error}"[:200]}
            )
        else:
            restored.append(name)
    defs: list[str] = []
    for item in cast(list[object], saved.get("definitions", [])):
        if (
            not isinstance(item, dict)
            or not isinstance(item.get("name"), str)
            or not isinstance(item.get("source"), str)
        ):
            continue
        name, source = item["name"], item["source"]
        try:
            exec(compile(source, "<albedo:state>", "exec"), namespace)
        except BaseException as error:
            failed.append(
                {"name": name, "reason": f"{type(error).__name__}: {error}"[:200]}
            )
        else:
            if source not in definitions.values():
                key = name
                while key in definitions:
                    key += "#2"
                definitions[key] = source
            if name not in restored:
                restored.append(name)
            defs.append(name)
    directory = saved.get("cwd")
    if isinstance(directory, str) and os.path.isdir(directory):
        os.chdir(directory)
    return {
        "restored": sorted(set(restored)),
        "defs": defs,
        "failed": failed,
        "engine": kind,
    }
