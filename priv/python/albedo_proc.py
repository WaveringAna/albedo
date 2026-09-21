"""Owned process groups: identify one, probe it, end it, report what happened.

The kernel's job supervision and the supervisor's checked signal helper both run
this ladder, so the two layers agree on what "terminated" means. A group is live
only while it holds a member we can still signal; a reaped leader or a group of
non-running (zombie) members is not work.
"""
from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
import asyncio
import os
import signal
import subprocess
import sys

TERM_GRACE = 0.25     # seconds a group gets to honour TERM
KILL_GRACE = 2.0      # seconds a group gets to die after KILL
PROBE_INTERVAL = 0.02


@dataclass(frozen=True)
class Group:
    """A target to end: a whole process group, or one process that leads none.

    `leader` identifies the leader where /proc exists, so a reused id is refused.
    """

    pgid: int
    leader: str | None = None
    whole: bool = True


@dataclass(frozen=True)
class Termination:
    """What one termination attempt established about one process group."""

    pgid: int | None
    signals: tuple[str, ...]
    gone: bool
    failures: tuple[str, ...] = ()
    note: str = ""

    def report(self) -> str:
        where = "no process group" if self.pgid is None else f"process group {self.pgid}"
        outcome = "terminated" if self.gone else "SURVIVED"
        sent = "+".join(self.signals) if self.signals else "no signal"
        detail = "; ".join((*self.failures, self.note)) if self.note else "; ".join(self.failures)
        return f"{where} {outcome} after {sent}" + (f": {detail}" if detail else "")

    def as_json(self) -> dict[str, object]:
        return {"pgid": self.pgid, "signals": list(self.signals), "gone": self.gone,
                "failures": list(self.failures), "note": self.note}


def start_token(stat: bytes) -> str | None:
    """Start time of one /proc/<pid>/stat line (field 22, after the command name)."""
    try:
        return stat.rsplit(b")", 1)[1].split()[19].decode()
    except (IndexError, UnicodeDecodeError):
        return None


def leader_token(pid: int) -> str | None:
    """Identity token for a live pid, where the platform exposes /proc."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as stat:
            return start_token(stat.read())
    except OSError:
        return None


def live_members(pgid: int) -> list[int] | None:
    """Pids in a group that are not zombies; None where /proc is unavailable."""
    try:
        entries = os.listdir("/proc")
    except OSError:
        if sys.platform != "darwin":
            return None
        # Darwin has no /proc. Ask its process table; EPERM alone never means dead.
        try:
            result = subprocess.run(["/bin/ps", "-A", "-o", "pid=", "-o", "pgid=", "-o", "stat="],
                                    capture_output=True, text=True, timeout=0.5, check=True)
            rows = [line.split() for line in result.stdout.splitlines()]
            return [int(pid) for pid, group, state in rows if int(group) == pgid and not state.startswith("Z")]
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
    members = []
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", "rb") as stat:
                fields = stat.read().rsplit(b")", 1)[1].split()
        except FileNotFoundError:
            continue  # process exited while enumerating
        except (OSError, IndexError):
            return None  # an incomplete view cannot prove the group empty
        if fields[0] == b"Z" or fields[2] != str(pgid).encode():
            continue
        members.append(int(entry))
    return members


def deliver(group: Group, sig: int) -> None:
    """Signal the target: its group, or the single process when it leads none."""
    (os.killpg if group.whole else os.kill)(group.pgid, sig)


def alive(group: Group) -> bool:
    """True while the target exists and still looks like the one we created."""
    try:
        deliver(group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True  # existence is known; inability to signal is a cleanup failure
    if group.leader is None:
        return True
    token = leader_token(group.pgid)
    return token is None or token == group.leader


def current(group: Group) -> bool:
    """alive/1 refined by membership: zombies awaiting reaping are not work."""
    if not alive(group):
        return False
    if not group.whole:
        return True
    members = live_members(group.pgid)
    return True if members is None else bool(members)


def send_signal(group: Group, sig: int) -> str | None:
    """Send one signal to a target; returns the failure text when it did not land."""
    try:
        deliver(group, sig)
        return None
    except ProcessLookupError:
        return None  # already gone; the probe decides
    except OSError as error:
        return f"{signal.Signals(sig).name} to {group.pgid}: {error.strerror or error}"


async def settled(live: dict[int, Group], window: float) -> dict[int, Group]:
    """The groups still alive after one shared wait, so batches share a deadline."""
    deadline = asyncio.get_running_loop().time() + window
    while True:
        remaining = {pgid: group for pgid, group in live.items() if alive(group)}
        if not remaining or asyncio.get_running_loop().time() >= deadline:
            return remaining
        await asyncio.sleep(PROBE_INTERVAL)


async def terminate(
    groups: Sequence[Group], term: float = TERM_GRACE, kill: float = KILL_GRACE
) -> list[Termination]:
    """End every group: TERM, then KILL, one shared deadline per step."""
    live = {group.pgid: group for group in groups if alive(group)}
    sent: dict[int, list[str]] = {pgid: [] for pgid in live}
    failures: dict[int, list[str]] = {pgid: [] for pgid in live}
    for sig, window in ((signal.SIGTERM, term), (signal.SIGKILL, kill)):
        for pgid, group in live.items():
            failure = send_signal(group, sig)
            sent[pgid].append(signal.Signals(sig).name)
            if failure is not None:
                failures[pgid].append(failure)
        live = await settled(live, window)
        if not live:
            break
    endings = []
    for group in groups:
        pgid, signals = group.pgid, sent.get(group.pgid, [])
        surviving, note = pgid in live, ""
        if surviving and not current(group):
            surviving, note = False, "only non-running members remained"
        endings.append(Termination(pgid, tuple(signals), not surviving, tuple(failures.get(pgid, [])), note))
    return endings
