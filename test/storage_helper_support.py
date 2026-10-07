"""Invoke production storage helpers or compiled test-only effect gates."""

import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def maintenance_command(home, executable=None, *, operation=None, gate=""):
    executable = executable or os.environ["ALBEDO_TEST_DAEMON"]
    if operation is None:
        return [executable, "storage", "maintain", str(home)]
    packages = sorted(Path(executable).parent.glob("*/ebin"))
    if not packages:
        raise RuntimeError("gated storage tests require the compiled test snapshot")
    return [
        str(ROOT / "priv/bin/albedo-daemon"),
        "erl",
        "-pa",
        *(str(package) for package in packages),
        "-eval",
        "albedo@@main:run(harness@storage_maintenance_support)",
        "-noshell",
        "-extra",
        operation,
        str(home),
        str(gate),
    ]
