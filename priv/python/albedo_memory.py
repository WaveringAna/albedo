"""The kernel's memory cap: a sampled physical footprint, not an allocator limit.

A cell that pushes the process past the cap is interrupted within an
interval; a single allocation larger than the cap is not refused, so this is
a guard against a runaway cell taking the namespace down, not a sandbox.
"""

from __future__ import annotations

import ctypes
import os
import struct
import sys

LIMIT = int(os.environ.get("ALBEDO_KERNEL_MEMORY_BYTES", str(256 * 1024 * 1024)))
INTERVAL = 0.1  # seconds between samples while a cell runs
# A cell that starts with the kernel already past the cap (a large variable
# left behind) may still grow this much, so `del big` and gc.collect() run.
SLACK = 8 * 1024 * 1024
PAGE = os.sysconf("SC_PAGE_SIZE") if hasattr(os, "sysconf") else 4096


def footprint() -> int | None:
    """Bytes this process holds in physical memory: the resident set from
    /proc, or Darwin's physical footprint (what vmmap and Activity Monitor
    report). None where neither can tell."""
    try:
        with open("/proc/self/statm", "rb") as statm:
            return int(statm.read().split()[1]) * PAGE
    except (OSError, IndexError, ValueError):
        return darwin_footprint(os.getpid()) if sys.platform == "darwin" else None


def darwin_footprint(pid: int) -> int | None:
    """ri_phys_footprint of a Darwin process's rusage_info_v0 (libproc's
    proc_pid_rusage), the 10th field after the 16-byte uuid."""
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
    except OSError:
        return None
    buffer = ctypes.create_string_buffer(96)
    if libproc.proc_pid_rusage(pid, 0, buffer) != 0:
        return None
    return struct.unpack_from("=Q", buffer.raw, 72)[0]


def threshold(start: int) -> int:
    """The footprint past which a cell that started at `start` is interrupted."""
    return max(LIMIT, start + SLACK)


def mebibytes(size: int) -> str:
    return f"{size / (1024 * 1024):.0f} MiB"
