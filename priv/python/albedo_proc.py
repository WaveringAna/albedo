"""Owned process groups: identify one, probe it, end it, report what happened.

The kernel's job supervision and the supervisor's checked signal helper both run
this ladder, so the two layers agree on what "terminated" means. A group is live
only while it holds a member we can still signal; a reaped leader or a group of
non-running (zombie) members is not work.
"""

from __future__ import annotations

from collections.abc import Callable, Sequence
from dataclasses import dataclass
from typing import Any
import asyncio
import ctypes
import os
import signal
import struct
import subprocess
import sys

TERM_GRACE = 0.25  # seconds a group gets to honour TERM
KILL_GRACE = 2.0  # seconds a group gets to die after KILL
PROBE_INTERVAL = 0.02
LIBC = ctypes.CDLL(None)


def reap_stopped_safely(loop: asyncio.AbstractEventLoop) -> None:
    """Let `loop` run children that get paused with SIGSTOP.

    Python 3.14's threaded child watcher waits with waitid(WEXITED | WNOWAIT),
    which macOS also answers for a stopped child, and then reaps with a blocking
    waitpid on the event loop: a job paused for a heavy slot froze the kernel.
    The replacement reaps in its thread with a waitpid that ignores stops, as
    3.13 did. Linux uses pidfds, which only wake on exit, and needs nothing.
    """
    threaded: Any = getattr(
        getattr(asyncio, "unix_events", None), "_ThreadedChildWatcher", None
    )
    if (
        sys.platform != "darwin"
        or threaded is None
        or not isinstance(getattr(loop, "_watcher", None), threaded)
    ):
        return

    class ExitWatcher(threaded):
        def _do_waitpid(
            self,
            loop: asyncio.AbstractEventLoop,
            expected_pid: int,
            callback: Callable[..., object],
            args: tuple[object, ...],
        ) -> None:
            try:
                returncode = os.waitstatus_to_exitcode(os.waitpid(expected_pid, 0)[1])
            except ChildProcessError:
                returncode = 255
            try:
                loop.call_soon_threadsafe(callback, expected_pid, returncode, *args)
            except RuntimeError:  # the loop closed first
                pass
            self._threads.pop(expected_pid, None)

    setattr(loop, "_watcher", ExitWatcher())


@dataclass(frozen=True)
class Group:
    """A target to end: a whole process group, or one process that leads none.

    `leader` identifies the leader by its start time, so a reused id is refused.
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
        where = (
            "no process group" if self.pgid is None else f"process group {self.pgid}"
        )
        outcome = "terminated" if self.gone else "SURVIVED"
        sent = "+".join(self.signals) if self.signals else "no signal"
        detail = (
            "; ".join((*self.failures, self.note))
            if self.note
            else "; ".join(self.failures)
        )
        return f"{where} {outcome} after {sent}" + (f": {detail}" if detail else "")

    def as_json(self) -> dict[str, object]:
        return {
            "pgid": self.pgid,
            "signals": list(self.signals),
            "gone": self.gone,
            "failures": list(self.failures),
            "note": self.note,
        }


def start_token(stat: bytes) -> str | None:
    """Start time of one /proc/<pid>/stat line (field 22, after the command name)."""
    try:
        return stat.rsplit(b")", 1)[1].split()[19].decode()
    except (IndexError, UnicodeDecodeError):
        return None


def leader_token(pid: int) -> str | None:
    """Identity token for a live pid: its start time, from /proc or, on
    Darwin, its process table entry. None where neither can tell."""
    try:
        with open(f"/proc/{pid}/stat", "rb") as stat:
            return start_token(stat.read())
    except OSError:
        return darwin_start(pid) if sys.platform == "darwin" else None


def darwin_start(pid: int) -> str | None:
    """A Darwin process's start time: the timeval that opens its kinfo_proc
    (sysctl CTL_KERN, KERN_PROC, KERN_PROC_PID). None for a pid not in use."""
    mib = (ctypes.c_int * 4)(1, 14, 1, pid)
    buffer = ctypes.create_string_buffer(1024)
    size = ctypes.c_size_t(len(buffer))
    if LIBC.sysctl(mib, 4, buffer, ctypes.byref(size), None, 0) != 0 or size.value < 12:
        return None
    seconds, micros = struct.unpack_from("=qi", buffer.raw)
    return f"{seconds}.{micros:06d}"


def table() -> list[tuple[int, int, int, bool]] | None:
    """Every process as (pid, ppid, pgid, zombie); None where the view is
    unavailable or incomplete."""
    try:
        entries = os.listdir("/proc")
    except OSError:
        if sys.platform != "darwin":
            return None
        # Darwin has no /proc. Ask its process table; EPERM alone never means dead.
        try:
            result = subprocess.run(
                [
                    "/bin/ps",
                    "-A",
                    "-o",
                    "pid=",
                    "-o",
                    "ppid=",
                    "-o",
                    "pgid=",
                    "-o",
                    "stat=",
                ],
                capture_output=True,
                text=True,
                timeout=0.5,
                check=True,
            )
            rows = [line.split() for line in result.stdout.splitlines()]
            return [
                (int(pid), int(ppid), int(pgid), state.startswith("Z"))
                for pid, ppid, pgid, state in rows
            ]
        except (OSError, subprocess.SubprocessError, ValueError):
            return None
    processes = []
    for entry in entries:
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat", "rb") as stat:
                fields = stat.read().rsplit(b")", 1)[1].split()
            processes.append(
                (int(entry), int(fields[1]), int(fields[2]), fields[0] == b"Z")
            )
        except FileNotFoundError:
            continue  # process exited while enumerating
        except (OSError, IndexError, ValueError):
            return None  # an incomplete view cannot prove the group empty
    return processes


def live_members(pgid: int) -> list[int] | None:
    """Pids in a group that are not zombies; None where the process table is unavailable."""
    processes = table()
    if processes is None:
        return None
    return [pid for pid, _, group, zombie in processes if group == pgid and not zombie]


def adopted(group: Group) -> set[int]:
    """Members of the group that a process which moved out of it still
    parents, with their descendants in it.

    ssh's ControlPersist master forks its ProxyCommand, then daemonizes out of
    the job's group: the proxy stays behind, and ending it ends the master and
    every later ssh that would have ridden it. Such a parent started after the
    group's leader, from inside the job; init or a subreaper that adopted an
    orphan was running before it, so orphans are never among these.
    """
    if not group.whole or group.leader is None:
        return set()
    processes = table()
    if processes is None:
        return set()
    groups = {pid: pgid for pid, _, pgid, _ in processes}
    members = {
        pid: ppid
        for pid, ppid, pgid, zombie in processes
        if pgid == group.pgid and not zombie
    }
    begun = float(group.leader)
    kept = set()
    for pid, ppid in members.items():
        if groups.get(ppid, group.pgid) == group.pgid:
            continue
        started = leader_token(ppid)
        if started is not None and float(started) >= begun:
            kept.add(pid)
    while descendants := {
        pid for pid, ppid in members.items() if ppid in kept and pid not in kept
    }:
        kept |= descendants
    return kept


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
        endings.append(
            Termination(
                pgid, tuple(signals), not surviving, tuple(failures.get(pgid, [])), note
            )
        )
    return endings


async def end(group: Group, leave_adopted: bool = False) -> Termination:
    """End a job's group. Once its command has exited on its own
    (`leave_adopted`), members a process that left the group still parents
    are that process's (`adopted`) and stay; the rest are ended one by one."""
    if not (leave_adopted and alive(group)):
        return (await terminate([group]))[0]
    signals: list[str] = []
    failures: list[str] = []
    rounds = 0
    while True:
        kept = adopted(group)
        if not kept:
            return (await terminate([group]))[0]
        rest = [pid for pid in live_members(group.pgid) or [] if pid not in kept]
        if not rest or rounds == 3:  # a member may fork while the others end
            note = f"kept {len(kept)} that a process which left the group parents"
            return Termination(
                group.pgid, tuple(signals), not rest, tuple(failures), note
            )
        rounds += 1
        targets = [Group(pid, leader_token(pid), whole=False) for pid in rest]
        for ending in await terminate(targets):
            signals += [name for name in ending.signals if name not in signals]
            failures += ending.failures
