"""Background jobs are owned process groups.

A job runs in its own session, so its shell leads a process group and one signal
reaches the command plus every descendant that stayed in that group. The group
is ended when the command ends, when its deadline passes, and at kernel
shutdown. What survives is reported, and unfinished work keeps its running slot.
"""
from __future__ import annotations

from collections import OrderedDict
from collections.abc import Callable, Generator
from albedo_api import PythonApi, OutputCapture, Send
import albedo_proc
import asyncio
import uuid

loop: asyncio.AbstractEventLoop
capture_factory: Callable[[str], OutputCapture]
preview_limit: int
jobs: dict[str, Job] = {}                        # every handle the session can address
active: dict[str, Job] = {}                      # unfinished work: the bounded resource
retained: OrderedDict[str, Job] = OrderedDict()  # finished handles, completion order
send: Send

ACTIVE_LIMIT = 64       # jobs owning running processes at once
RETAINED_LIMIT = 64     # finished handles still addressable through `jobs`
COMPLETION_GRACE = 0.1  # seconds to keep reading after the command exits
EXIT_INTERVAL = 0.01    # seconds between exit checks while the command runs
SHUTDOWN_TERM = 0.25    # shared by every live group at shutdown
SHUTDOWN_KILL = 1.0


class Job:
    """One background command and the process group it owns."""

    def __init__(self, command: str, timeout: float) -> None:
        self.id: str = uuid.uuid4().hex
        self.command: str = command
        self.process: asyncio.subprocess.Process | None = None
        self.group: albedo_proc.Group | None = None
        self.exit_code: int | None = None
        self.timed_out: bool = False
        self.started: float = loop.time()
        self.duration: float | None = None  # wall seconds once the command ended
        self.termination: albedo_proc.Termination | None = None
        self.capture: OutputCapture = capture_factory(self.id)
        self.ending: asyncio.Task[albedo_proc.Termination] | None = None
        self.spawning = loop.create_task(asyncio.create_subprocess_shell(
            self.command, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT, start_new_session=True))
        self.task: asyncio.Task[Job] = loop.create_task(self._run(timeout))
        self.task.add_done_callback(self._cancelled)
        active[self.id] = self
        jobs[self.id] = self

    def claim(self) -> albedo_proc.Group | None:
        """The group this job owns, derived again when a late spawn beat the assignment."""
        if self.group is None and self.process is not None:
            self.group = albedo_proc.Group(self.process.pid, albedo_proc.leader_token(self.process.pid))
            send({"type": "job_start", "id": self.id, "pgid": self.group.pgid, "leader": self.group.leader})
        return self.group

    def _cancelled(self, task: asyncio.Task[Job]) -> None:
        if task.cancelled():
            # Cancellation before _run starts skips its finally block.
            loop.create_task(self.stop())

    async def _spawn(self) -> asyncio.subprocess.Process:
        process = await asyncio.shield(self.spawning)
        self.process = process
        self.claim()
        return process

    async def _run(self, timeout: float) -> Job:
        try:
            process = self.process = await self._spawn()
            self.exit_code = await asyncio.wait_for(self._drain(process), timeout)
        except asyncio.TimeoutError:
            self.timed_out = True
        except asyncio.CancelledError:
            pass
        except Exception as error:
            self.capture.write(f"{type(error).__name__}: {error}\n")
        finally:
            ending = await self.stop()
            if self.exit_code is None and self.process is not None:
                self.exit_code = await self._status(self.process)
            self.duration = loop.time() - self.started
            if self.timed_out:
                self.capture.write(f"\n[deadline exceeded after {timeout:g}s; {ending.report()}]\n")
            elif not ending.gone:
                self.capture.write(f"\n[cleanup failed: {ending.report()}]\n")
            send({"type": "job", "id": self.id, "exit_code": self.exit_code,
                  "timed_out": self.timed_out, "cleanup": ending.as_json()})
            release(self)
        return self

    async def _drain(self, process: asyncio.subprocess.Process) -> int:
        """Read output while the command runs; a descendant holding the pipe does not extend it."""
        stdout = process.stdout
        assert stdout is not None  # stdout=PIPE above
        copying = loop.create_task(self._copy(stdout))
        exiting = loop.create_task(self._exited(process))
        try:
            finished, _ = await asyncio.wait({copying, exiting}, return_when=asyncio.FIRST_COMPLETED)
            if copying not in finished:
                await asyncio.wait({copying}, timeout=COMPLETION_GRACE)  # take what the pipe holds
            return await exiting
        finally:
            for task in (copying, exiting):
                if not task.done():
                    task.cancel()

    async def _status(self, process: asyncio.subprocess.Process, window: float = 1.0) -> int | None:
        """The command's exit status after its group is gone; bounded, never assumed."""
        deadline = loop.time() + window
        while process.returncode is None and loop.time() < deadline:
            await asyncio.sleep(EXIT_INTERVAL)
        return process.returncode

    async def _exited(self, process: asyncio.subprocess.Process) -> int:
        """The command's own exit status; process.wait() would also wait for its descendants."""
        while process.returncode is None:
            await asyncio.sleep(EXIT_INTERVAL)
        return process.returncode

    async def _copy(self, stream: asyncio.StreamReader) -> None:
        while chunk := await stream.read(8192):
            self.capture.write(chunk.decode("utf-8", errors="replace"))

    def __await__(self) -> Generator[object, None, Job]:
        return asyncio.shield(self.task).__await__()

    def poll(self):
        return self.exit_code

    @property
    def returncode(self) -> int | None:
        """`exit_code` under subprocess's name; both spellings answer."""
        return self.exit_code

    def tail(self, n: int = 4000) -> str:
        data = self.capture.tail_data
        return bytes(data[-max(1, min(n, preview_limit)):]).decode("utf-8", errors="replace")

    async def stop(self) -> albedo_proc.Termination:
        """End the job's process group. A failed attempt stays retryable."""
        if self.termination is not None and self.termination.gone:
            return self.termination
        process = self.process
        if process is None:
            try:
                process = await self._spawn()
            except Exception as error:
                self.termination = albedo_proc.Termination(None, (), True, (f"spawn failed: {error}",))
                release(self)
                return self.termination
        if self.ending is None or self.ending.done():
            group = self.claim()
            self.ending = loop.create_task(_terminate_one(group) if group is not None else _unstarted())
        ending = await asyncio.shield(self.ending)
        self.termination = ending
        release(self)
        if self.task.done():
            send({"type": "job", "id": self.id, "exit_code": process.returncode,
                  "timed_out": self.timed_out, "cleanup": ending.as_json()})
        return ending

    def __repr__(self) -> str:
        return (f"Job(id={self.id!r}, exit_code={self.exit_code!r}, "
                f"timed_out={self.timed_out!r}, duration={self.duration!r}, "
                f"bytes={self.capture.seen})")


async def _terminate_one(group: albedo_proc.Group) -> albedo_proc.Termination:
    """One group through the ladder: the batch form with a batch of one."""
    return (await albedo_proc.terminate([group]))[0]


async def _unstarted() -> albedo_proc.Termination:
    return albedo_proc.Termination(None, (), True, ("process never started",))


def release(job: Job) -> None:
    """Free the running slot only when the group is gone; a leaked group keeps it."""
    if job.termination is None or not job.termination.gone or active.pop(job.id, None) is None:
        return
    retained.pop(job.id, None)
    retained[job.id] = job
    while len(retained) > RETAINED_LIMIT:
        _, evicted = retained.popitem(last=False)
        if jobs.get(evicted.id) is evicted:
            del jobs[evicted.id]


def bash(command: object, *, timeout: float = 300) -> Job:
    """Start immediately; await the handle to wait.

    Output stays on the handle: job.tail() for the recent tail, output.read(job.id)
    for the retained whole. Jobs survive cell completion and each owns its process
    group. Only unfinished work counts against the concurrent quota; finished
    handles stay usable in `jobs` until newer ones displace them.
    """
    if not isinstance(command, str) or not 0 < timeout <= 3600:
        raise ValueError("command must be text; 0 < timeout <= 3600 required")
    if len(active) >= ACTIVE_LIMIT:
        raise RuntimeError(f"{ACTIVE_LIMIT} jobs still own running processes; await or stop one first")
    return Job(command, timeout)


async def close() -> None:
    """Kernel shutdown: end every live group inside one shared deadline."""
    owned = list(active.values())
    await asyncio.gather(*(job._spawn() for job in owned if job.process is None), return_exceptions=True)
    live = [(job, group) for job in owned if (group := job.claim()) is not None]
    if not live:
        return
    endings = await albedo_proc.terminate([group for _, group in live], SHUTDOWN_TERM, SHUTDOWN_KILL)
    for (job, _), ending in zip(live, endings):
        job.termination = ending
        release(job)
    failures = [ending.report() for ending in endings if not ending.gone]
    if failures:
        send({"type": "cleanup", "module": "bash", "failures": failures})


def setup(api: PythonApi) -> dict[str, object]:
    global loop, capture_factory, preview_limit, jobs, active, retained, send
    loop, capture_factory, preview_limit, send = api.loop, api.capture, api.preview, api.send
    jobs, active, retained = {}, {}, OrderedDict()
    api.background_handle(Job)
    api.on_shutdown(close)
    return {"bash": bash, "jobs": jobs}
