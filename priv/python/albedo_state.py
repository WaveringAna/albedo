"""Bounded, atomic snapshots of the kernel-owned namespace and definitions."""

from __future__ import annotations

import os
import pickle
import tempfile
import types
from typing import Any, cast

# Saved state is the session's own namespace, written by this kernel into the
# daemon's home. Loading pickle and replaying definitions share the transcript's trust domain.
STATE_MAX = 64 * 1024 * 1024
STATE_MAX_VALUE = 8 * 1024 * 1024
DEFINITION_MAX = 256 * 1024
DEFINITION_MAX_VALUE = 32 * 1024


def engine() -> tuple[object, str]:
    """dill when it is installed; pickle keeps plain data working without it."""
    try:
        import dill

        dill.settings["recurse"] = True
        return dill, "dill"
    except ImportError:
        return pickle, "pickle"


def save_state(
    path: str,
    namespace: dict[str, object],
    definitions: dict[str, str],
    injected: set[str],
) -> dict[str, object]:
    """Serialise values and readable top-level definitions within fixed caps."""
    serialiser, kind = cast("Any", engine())
    payload: dict[str, bytes] = {}
    skipped: list[dict[str, str]] = []
    total = 0
    largest: list[tuple[str, int]] = []
    for name in list(namespace.keys()):
        if name.startswith("_") or name in injected:
            continue
        value = namespace.get(name, injected)
        if value is injected:
            continue
        try:
            blob = cast(bytes, serialiser.dumps(value))
        except BaseException as error:
            if name not in definitions or not isinstance(
                value, (types.FunctionType, type, types.ModuleType)
            ):
                skipped.append(
                    {"name": name, "reason": f"{type(error).__name__}: {error}"[:200]}
                )
            continue
        if len(blob) > STATE_MAX_VALUE:
            if name not in definitions or not isinstance(
                value, (types.FunctionType, type, types.ModuleType)
            ):
                skipped.append(
                    {
                        "name": name,
                        "reason": f"{len(blob)} bytes exceeds the per-variable cap",
                    }
                )
        elif total + len(blob) > STATE_MAX:
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
        "saved": sorted(set(payload) | {item["name"] for item in saved_definitions}),
        "defs": [item["name"] for item in saved_definitions],
        "skipped": skipped,
        "largest": [{"name": name, "bytes": size} for name, size in largest[:5]],
        "bytes": total,
        "engine": kind,
    }


def load_state(
    path: str, namespace: dict[str, object], definitions: dict[str, str]
) -> dict[str, object]:
    """Restore pickled values, then replay definitions in their saved order."""
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
