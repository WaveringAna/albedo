"""Checked group termination for the erlang supervisor.

Erlang runs this as its own process, so supervision keeps making progress when
the kernel cannot (a native cell holding the GIL, a wedged interpreter), and so
the supervisor never parses kill(1) error text or guesses an exit status. One
argv carries the request; one JSON object on stdout carries the verdict.
"""

from __future__ import annotations

import signal

import asyncio
import json
import os
import sys

import albedo_proc

TERM_MS = 250
KILL_MS = 1000  # the supervisor's remaining budget is short: this is the last resort


def budget(request: dict, name: str, default: int) -> float:
    """Seconds for one ladder step, clamped to something a caller can wait for."""
    value = request.get(name, default)
    return (
        min(max(value, 10), default) / 1000
        if isinstance(value, int)
        else default / 1000
    )


def target(spec: object) -> albedo_proc.Group:
    """One requested target: a process group, or one process that leads none."""
    if not isinstance(spec, dict):
        raise ValueError("target must be an object")
    pgid = spec.get("pgid")
    operand = pgid if isinstance(pgid, int) else spec.get("pid")
    if not isinstance(operand, int) or operand <= 1:
        raise ValueError("target needs a pgid or pid above 1")
    leader = spec.get("leader")
    whole = isinstance(pgid, int)
    if not whole:
        try:
            whole = os.getpgid(operand) == operand
        except (ProcessLookupError, PermissionError):
            pass
    return albedo_proc.Group(
        operand, leader if isinstance(leader, str) else None, whole
    )


def supervise(request: object) -> dict[str, object]:
    if not isinstance(request, dict):
        raise ValueError("request must be an object")
    specs = request.get("targets")
    if not isinstance(specs, list):
        raise ValueError("request needs a target list")
    targets = [target(spec) for spec in specs]
    endings = asyncio.run(
        albedo_proc.terminate(
            targets,
            term=budget(request, "term_ms", TERM_MS),
            kill=budget(request, "kill_ms", KILL_MS),
        )
    )
    return {
        "targets": [
            {**ending.as_json(), "label": spec.get("label")}
            for spec, ending in zip(specs, endings)
        ]
    }


def main(request: str) -> int:
    try:
        answer: dict[str, object] = {"ok": True, **supervise(json.loads(request))}
        status = 0
    except Exception as error:
        answer, status = {"ok": False, "error": f"{type(error).__name__}: {error}"}, 2
    print(json.dumps(answer))
    return status


if __name__ == "__main__":
    # Default SIGALRM terminates even a wedged interpreter; no Python handler.
    # The owning port waits longer than this before reporting a helper timeout.
    signal.signal(signal.SIGALRM, signal.SIG_DFL)
    signal.alarm(3)
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "{}"))
