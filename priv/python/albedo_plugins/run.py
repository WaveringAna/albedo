"""Programs start as background jobs, and jobs are owned process groups.

run(program, *args) starts one program without a shell. A job runs in its own
session, so its program leads a process group and one signal reaches it plus
every descendant that stayed in that group. The group
is ended when the command ends, when its deadline passes, and at kernel
shutdown. What survives is reported, and unfinished work stays owned.
When the command ends on its own, members a process that left the group still
parents stay with it: ssh's ControlPersist master daemonizes out of the job
but leaves its ProxyCommand in the group, and ending that ends the master.

A job that finishes with its result unread wakes the session: the kernel tells
the host, the host submits a user turn naming the job, and the model never has
to poll or await. Reading the result (tail, poll, await, output.read) or
stopping the job withdraws the wake, and a busy session is retried until it
goes idle, so a notice can never overtake the read that satisfies it. Jobs
still owed when the retry lands share one notice, and so one turn.
"""

from __future__ import annotations

from collections import OrderedDict
from collections.abc import Callable, Generator
from typing import cast
from albedo_api import (
    Host,
    PythonApi,
    OutputCapture,
    Send,
    Text,
    check_timeout,
    excerpt,
)
import albedo_proc
import albedo_shell
import albedo_shims
import albedo_trace
import asyncio
import os
import shlex
import shutil
import sys
import uuid

loop: asyncio.AbstractEventLoop
capture_factory: Callable[[str], OutputCapture]
preview_limit: int
jobs: dict[str, Job] = {}  # every handle the session can address
active: dict[str, Job] = {}  # unfinished work: the bounded resource
retained: OrderedDict[str, Job] = OrderedDict()  # finished handles, completion order
owed: dict[str, Job] = {}  # finished with results unread, in completion order
announcer: asyncio.Task[None] | None = None
send: Send
host: Host | None = None
watch_output: Callable[[str, Callable[[], None]], None] | None = None
forget_output: Callable[[str], None] | None = None

ACTIVE_LIMIT = 64  # active jobs in one kernel
RETAINED_LIMIT = 64  # finished handles still addressable through `jobs`
COMPLETION_GRACE = 0.1  # seconds to keep reading after the command exits
SHUTDOWN_TERM = 0.25  # shared by every live group at shutdown
SHUTDOWN_KILL = 1.0
NICENESS = 10
# macOS runs utility-QoS work below the interface, so a busy swarm yields.
TASKPOLICY = shutil.which("taskpolicy") if sys.platform == "darwin" else None
NOTICE_RETRY = 2.0  # seconds between wake attempts while the session runs
NOTICE_COMMAND_CAP = 200  # command characters a wake notice carries


class Outlet:
    """A job's output on its way to other jobs' stdin, besides its capture."""

    def __init__(self) -> None:
        self.feeds: list[Feed] = []
        self.closed = False  # the program's output ended; feeds get EOF
        self.reading: asyncio.ReadTransport | None = None
        self.held: set[Feed] = set()  # readers whose stdin is full

    def write(self, data: bytes) -> None:
        for feed in self.feeds:
            feed.write(data)

    def close(self) -> None:
        if not self.closed:
            self.closed = True
            for feed in self.feeds:
                feed.end()

    def cut(self) -> None:
        """Stop reading the program's output once nothing wants it, so its
        next write fails the way it would into a closed shell pipe."""
        if self.reading is not None and not self.reading.is_closing():
            self.reading.close()

    def hold(self, feed: Feed) -> None:
        self.held.add(feed)
        if self.reading is not None:
            self.reading.pause_reading()

    def release(self, feed: Feed) -> None:
        self.held.discard(feed)
        if not self.held and self.reading is not None and not self.reading.is_closing():
            self.reading.resume_reading()


class Feed:
    """One job's output into another's stdin, the way a shell pipe carries it:
    bytes wait until the reader starts, a full reader pauses the writer, and
    once every reader has stopped, the writer's next write fails (SIGPIPE)."""

    def __init__(self, writer: Job, retained: bytes) -> None:
        self.writer = writer
        self.pending = bytearray(retained)
        self.pipe: asyncio.WriteTransport | None = None
        self.ended = False
        self.broken = False

    def write(self, data: bytes) -> None:
        if self.broken:
            return
        if self.pipe is None:
            self.pending.extend(data)
        else:
            self.pipe.write(data)

    def end(self) -> None:
        self.ended = True
        if self.pipe is not None and not self.pipe.is_closing():
            self.pipe.close()

    def connect(self, pipe: asyncio.WriteTransport) -> None:
        self.pipe = pipe
        pipe.write(bytes(self.pending))
        self.pending.clear()
        if self.ended:
            pipe.close()

    def lost(self) -> None:
        """The reader's stdin closed before the writer's output ended."""
        self.writer.outlet.release(self)
        if self.ended or self.broken:
            return
        self.broken = True
        if all(feed.broken for feed in self.writer.outlet.feeds):
            self.writer.outlet.cut()


class Command(asyncio.SubprocessProtocol):
    """Separate command exit from pipe EOF, without a timer per running job."""

    def __init__(
        self, capture: OutputCapture, outlet: Outlet, feed: Feed | None
    ) -> None:
        self.capture = capture
        self.outlet = outlet
        self.feed = feed  # what fills this program's stdin, if a job does
        self.exited: asyncio.Future[int] = loop.create_future()
        self.drained: asyncio.Future[None] = loop.create_future()
        self.transport: asyncio.SubprocessTransport
        self.pid: int

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        self.transport = cast(asyncio.SubprocessTransport, transport)
        self.pid = self.transport.get_pid()
        self.outlet.reading = cast(
            asyncio.ReadTransport, self.transport.get_pipe_transport(1)
        )

    @property
    def returncode(self) -> int | None:
        return self.transport.get_returncode()

    def pipe_data_received(self, fd: int, data: bytes) -> None:
        # Capture is bounded and synchronous; no unbounded reader queue.
        self.capture.write_bytes(data)
        self.outlet.write(data)

    def pipe_connection_lost(self, fd: int, exc: Exception | None) -> None:
        if fd == 0:
            if self.feed is not None:
                self.feed.lost()
            return  # stdin written and closed; output is still coming
        self.outlet.close()
        if not self.drained.done():
            self.drained.set_result(None)
        if self.exited.done():
            self.transport.close()

    def pause_writing(self) -> None:
        if self.feed is not None:
            self.feed.writer.outlet.hold(self.feed)

    def resume_writing(self) -> None:
        if self.feed is not None:
            self.feed.writer.outlet.release(self.feed)

    def process_exited(self) -> None:
        code = self.returncode
        assert code is not None
        self.exited.set_result(code)
        if self.drained.done():
            self.transport.close()


Data = str | bytes | os.PathLike[str]


async def spawn(
    argv: list[str],
    capture: OutputCapture,
    cwd: str | None,
    env: dict[str, str] | None,
    stdin: Data | None,
    outlet: Outlet,
    feed: Feed | None,
) -> Command:
    """Start argv at a lower priority than the person at the machine, with
    stdin fed from text, bytes, a file, or another job, and stdout and stderr
    joined."""
    if TASKPOLICY is not None:
        argv = [TASKPOLICY, "-c", "utility", *argv]
    file = open(stdin, "rb") if isinstance(stdin, os.PathLike) else None
    piped = stdin is not None or feed is not None
    source = file or (asyncio.subprocess.PIPE if piped else asyncio.subprocess.DEVNULL)
    try:
        _, process = await loop.subprocess_exec(
            lambda: Command(capture, outlet, feed),
            *argv,
            stdin=source,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
            cwd=cwd,
            env=env,
            start_new_session=True,
            preexec_fn=_lower_priority,
        )
    finally:
        if file is not None:
            file.close()
    pipe = cast(asyncio.WriteTransport | None, process.transport.get_pipe_transport(0))
    if pipe is not None and feed is not None:
        feed.connect(pipe)
    elif pipe is not None and isinstance(stdin, (str, bytes)):
        pipe.write(stdin.encode() if isinstance(stdin, str) else stdin)
        pipe.close()
    return process


def _lower_priority() -> None:
    try:
        os.nice(NICENESS)
    except OSError:
        pass


class Job:
    """One background program and the process group it owns."""

    def __init__(
        self,
        argv: list[str],
        timeout: float,
        *,
        cwd: str | None = None,
        env: dict[str, str] | None = None,
        stdin: Data | Job | None = None,
        traced: bool = True,
        service: bool = False,
    ) -> None:
        self.service = service  # expected to run on; its end is not what we wait for
        self.source: Job | None = (
            stdin if isinstance(stdin, Job) else None
        )  # whose output is our stdin
        self.feed = self.source._reader() if self.source is not None else None
        self.outlet = Outlet()
        self.id: str = uuid.uuid4().hex
        self.argv: list[str] = argv
        self.command: str = shlex.join(argv)  # what ran, as one line to read
        self.process: Command | None = None
        self.group: albedo_proc.Group | None = None
        self.exit_code: int | None = None
        self.timed_out: bool = False
        self.started: float = loop.time()
        self.duration: float | None = None  # seconds it ran, once it ended
        self.termination: albedo_proc.Termination | None = None
        self.capture: OutputCapture = capture_factory(self.id)
        self.ending: asyncio.Task[albedo_proc.Termination] | None = None
        self._awaited = False  # someone awaited this job; its result reached them
        self._read = False  # the finished result was read; no wake is owed
        self._remote = os.environ.get("ALBEDO_REMOTE_TARGET") or None
        self._starting = (
            False  # the OS spawn began; from then on it must finish, not be cancelled
        )
        if watch_output is not None:
            watch_output(self.id, self._mark_read)
        if traced:
            albedo_trace.note("run", self.command)
        data = None if isinstance(stdin, Job) else stdin
        with albedo_trace.unobserved():  # the cell ran argv, not the wrapper around it
            self.spawning = loop.create_task(self._launch(cwd, env, data, self.feed))
        self.task: asyncio.Task[Job] = loop.create_task(self._run(timeout))
        self.task.add_done_callback(self._cancelled)
        active[self.id] = self
        jobs[self.id] = self

    async def _launch(
        self,
        cwd: str | None,
        env: dict[str, str] | None,
        stdin: Data | None,
        feed: Feed | None,
    ) -> Command:
        self._starting = True
        return await spawn(self.argv, self.capture, cwd, env, stdin, self.outlet, feed)

    def _reader(self) -> Feed:
        """A feed of this job's output for another job's stdin: what it wrote
        so far, then the rest as it comes. Piping it retires its own wake; the
        reader's notice names the pipeline."""
        if self.capture.seen > len(self.capture.data):
            raise ValueError(
                f"job {self.id} wrote more than it retains ({len(self.capture.data)} bytes); "
                "pipe from it before it runs: run(...).pipe(...) in one expression"
            )
        feed = Feed(self, bytes(self.capture.data))
        self.outlet.feeds.append(feed)
        if self.outlet.closed:
            feed.end()
        self._read = True
        return feed

    def pipe(
        self,
        program: object,
        *args: object,
        cwd: str | os.PathLike[str] | None = None,
        env: dict[str, object] | None = None,
        timeout: float = 300,
    ) -> Job:
        """Start a program reading this job's output, like a shell `|`:
        run("git", "log").pipe("rg", "fix"). Returns the reader's handle."""
        return run(program, *args, cwd=cwd, env=env, stdin=self, timeout=timeout)

    @property
    def pipeline(self) -> str:
        """The command line this job ends, with every job piped into it."""
        return (
            f"{self.source.pipeline} | {self.command}"
            if self.source is not None
            else self.command
        )

    def claim(self) -> albedo_proc.Group | None:
        """The group this job owns, derived again when a late spawn beat the assignment."""
        if self.group is None and self.process is not None:
            self.group = albedo_proc.Group(
                self.process.pid, albedo_proc.leader_token(self.process.pid)
            )
            send(
                {
                    "type": "job_start",
                    "id": self.id,
                    "pid": self.process.pid,
                    "pgid": self.group.pgid,
                    "leader": self.group.leader,
                    "command": self.pipeline[:4096],
                    "service": self.service,
                }
            )
        return self.group

    def _cancelled(self, task: asyncio.Task[Job]) -> None:
        if task.cancelled():
            # Cancellation before _run starts skips its finally block.
            loop.create_task(self._stop())

    async def _spawn(self) -> Command:
        process = await asyncio.shield(self.spawning)
        self.process = process
        self.claim()
        return process

    async def _run(self, timeout: float) -> Job:
        try:
            process = self.process = await self._spawn()
            await asyncio.wait_for(asyncio.shield(process.exited), timeout)
            self.exit_code = await self._drain(process)
        except asyncio.TimeoutError:
            self.timed_out = True
        except asyncio.CancelledError:
            pass
        except Exception as error:
            self.capture.write(f"{type(error).__name__}: {error}\n")
        finally:
            self.outlet.close()
            if self.feed is not None and self.feed.pipe is None:
                self.feed.lost()  # never started, so never read
            ending = await self._stop(exited=self.exit_code is not None)
            if self.exit_code is None and self.process is not None:
                self.exit_code = await self._status(self.process)
            if self.process is not None and ending.gone:
                self.process.transport.close()
            self.duration = loop.time() - self.started
            if self.timed_out:
                self.capture.write(
                    f"\n[deadline exceeded after {timeout:g}s; {ending.report()}]\n"
                )
            elif not ending.gone:
                self.capture.write(f"\n[cleanup failed: {ending.report()}]\n")
            send(
                {
                    "type": "job",
                    "id": self.id,
                    "exit_code": self.exit_code,
                    "timed_out": self.timed_out,
                    "cleanup": ending.as_json(),
                }
            )
            release(self)
            if host is not None and not self._awaited:
                owe(self)
        return self

    async def _drain(self, process: Command) -> int:
        """Read output while the command runs; a descendant holding the pipe does not extend it."""
        code = await asyncio.shield(process.exited)
        await asyncio.wait({process.drained}, timeout=COMPLETION_GRACE)
        return code

    async def _status(self, process: Command, window: float = 1.0) -> int | None:
        """The command's exit status after its group is gone; bounded, never assumed."""
        try:
            return await asyncio.wait_for(asyncio.shield(process.exited), window)
        except asyncio.TimeoutError:
            return process.returncode

    def __await__(self) -> Generator[object, None, Job]:
        self._awaited = True
        return asyncio.shield(self.task).__await__()

    def poll(self):
        if self.exit_code is not None:
            self._read = True
        return self.exit_code

    @property
    def returncode(self) -> int | None:
        """`exit_code` under subprocess's name; both spellings answer."""
        return self.poll()

    def tail(self, n: int = 4000, *, lines: int | None = None) -> Text:
        """The last n characters of output, or its last `lines` lines."""
        if self.exit_code is not None:
            self._read = True
        text = self.capture.tail().decode("utf-8", errors="replace")
        return excerpt(text, min(n, preview_limit), lines, end=True)

    def head(self, n: int = 4000, *, lines: int | None = None) -> Text:
        """The first n characters of output, or its first `lines` lines."""
        if self.exit_code is not None:
            self._read = True
        return excerpt(
            self.capture.read(0, preview_limit), min(n, preview_limit), lines, end=False
        )

    def _mark_read(self) -> None:
        """output.read reached this job's channel; a finished result is read."""
        if self.exit_code is not None:
            self._read = True

    @property
    def _unreported(self) -> bool:
        """Finished, and its result has reached no one yet."""
        return not self._read and not self._awaited

    def _facts(self) -> dict[str, object]:
        """What a wake notice says about this job."""
        command = self.pipeline[:NOTICE_COMMAND_CAP] + (
            "..." if len(self.pipeline) > NOTICE_COMMAND_CAP else ""
        )
        outcome = (
            "timed out"
            if self.timed_out
            else f"exit_code={self.exit_code}"
            if self.exit_code is not None
            else "exit status unknown"
        )
        seconds = (
            f"ran {self.duration:.1f}s"
            if self.duration is not None
            else "unknown duration"
        )
        return {
            "id": self.id,
            "command": command,
            "where": f" on {self._remote}" if self._remote else "",
            "summary": f"{outcome}, {seconds}",
            "exit_code": self.exit_code,
            "timed_out": self.timed_out,
            "duration": self.duration,
            "host": self._remote,
        }

    async def stop(self) -> albedo_proc.Termination:
        """End the job's process group. A failed attempt stays retryable."""
        self._read = True  # an explicit stop is its own report; no wake is owed
        return await self._stop()

    async def _stop(self, exited: bool = False) -> albedo_proc.Termination:
        """End the group; once the command `exited` on its own, what a process
        that left the group still parents stays with that process."""
        if self.termination is not None and self.termination.gone:
            return self.termination
        process = self.process
        if process is None:
            if not self._starting:
                self.spawning.cancel()
            try:
                process = await self._spawn()
            except (Exception, asyncio.CancelledError) as error:
                self.termination = albedo_proc.Termination(
                    None, (), True, (f"spawn failed: {error}",)
                )
                release(self)
                if self.task.done():
                    send(
                        {
                            "type": "job",
                            "id": self.id,
                            "exit_code": None,
                            "timed_out": False,
                            "cleanup": self.termination.as_json(),
                        }
                    )
                return self.termination
        if self.ending is None or self.ending.done():
            group = self.claim()
            self.ending = loop.create_task(
                albedo_proc.end(group, exited) if group is not None else _unstarted()
            )
        ending = await asyncio.shield(self.ending)
        self.termination = ending
        release(self)
        if self.task.done():
            send(
                {
                    "type": "job",
                    "id": self.id,
                    "exit_code": process.returncode,
                    "timed_out": self.timed_out,
                    "cleanup": ending.as_json(),
                }
            )
        return ending

    def __repr__(self) -> str:
        return (
            f"Job(id={self.id!r}, exit_code={self.exit_code!r}, "
            f"timed_out={self.timed_out!r}, duration={self.duration!r}, "
            f"bytes={self.capture.seen})"
        )


async def _unstarted() -> albedo_proc.Termination:
    return albedo_proc.Termination(None, (), True, ("process never started",))


def release(job: Job) -> None:
    """Retire active work only when its group is gone."""
    if (
        job.termination is None
        or not job.termination.gone
        or active.pop(job.id, None) is None
    ):
        return
    retained.pop(job.id, None)
    retained[job.id] = job
    while len(retained) > RETAINED_LIMIT:
        _, evicted = retained.popitem(last=False)
        if jobs.get(evicted.id) is evicted:
            del jobs[evicted.id]


def forget(job: Job) -> None:
    """Drop a finished job a plugin ran for its own purposes: it leaves `jobs`
    and the retained output channels, so internal work never shows up beside,
    or crowds out, the model's own jobs and cells."""
    if jobs.get(job.id) is job:
        del jobs[job.id]
    retained.pop(job.id, None)
    if forget_output is not None:
        forget_output(job.id)


def owe(job: Job) -> None:
    """Queue a finished job's wake. One announcer carries every owed result,
    so jobs that finish during a turn wake the session once, not once each."""
    global announcer
    owed[job.id] = job
    if announcer is None or announcer.done():
        announcer = loop.create_task(_announce())


async def _announce() -> None:
    """Wake the session for every owed result, retrying while it runs.

    A busy session answers with a refusal rather than queueing, so the notice
    retries until the run ends, naming whatever is still owed then; a read or
    await in the meantime retires that job, which is also the creating-cell
    barrier: a cell that will await its own job suppresses the wake before any
    turn can start.
    """
    while True:
        for job in [job for job in owed.values() if not job._unreported]:
            del owed[job.id]
        notify = host
        if not owed or notify is None:
            return
        batch = list(owed.values())
        try:
            await notify("jobs.completed", notice([job._facts() for job in batch]))
        except Exception as error:
            if getattr(error, "code", "") == "busy":
                await asyncio.sleep(NOTICE_RETRY)
                continue
            for job in batch:
                job.capture.write(f"\n[completion notice not delivered: {error}\n")
        for job in batch:
            owed.pop(job.id, None)


# A job on a remote.connect() host lives in that kernel's `jobs`, not the
# model's, so its notice names the reference rem.run returned instead.
REMOTE_READING = (
    " a job on another host is read with .tail() on the reference rem.run"
    " returned, or await rem.output.read(id) on that connection."
)


def _name(job: dict[str, object]) -> str:
    """How a notice names a job: its `jobs` entry here, or a remote job's id."""
    return repr(job["id"]) if job["host"] else f"jobs[{job['id']!r}]"


def notice(facts: list[dict[str, object]]) -> dict[str, object]:
    """The wake turn's display text, model text, and the facts behind both."""
    advice = (
        " no user sent this message; use the result if the session's work needs"
        " it, otherwise acknowledge briefly and stay idle.</system-note>"
    )
    if len(facts) == 1:
        [job] = facts
        reading = (
            " its handle is the reference rem.run returned; its .tail() or"
            f" await rem.output.read({job['id']!r}) on that connection reads its output."
            if job["host"]
            else f" its handle is jobs[{job['id']!r}] in python; jobs[{job['id']!r}].tail() or"
            f" output.read({job['id']!r}) reads its output."
        )
        text = (
            "<system-note>a background job finished with its result unread"
            f"{job['where']}: {job['summary']}, command: {job['command']}."
            + reading
            + advice
        )
    else:
        listed = "; ".join(
            f"{_name(job)}{job['where']}: {job['summary']}, command: {job['command']}"
            for job in facts
        )
        remote = any(job["host"] for job in facts)
        text = (
            f"<system-note>{len(facts)} background jobs finished with their results"
            f" unread: {listed}. jobs[id].tail() or output.read(id) reads one's"
            " output." + (REMOTE_READING if remote else "") + advice
        )
    display = "\n".join(
        f"job finished{job['where']} ({job['summary']}): {job['command']}"
        for job in facts
    )
    return {"display": display, "text": text, "jobs": facts}


def run(
    program: object,
    *args: object,
    cwd: str | os.PathLike[str] | None = None,
    env: dict[str, object] | None = None,
    stdin: Data | Job | None = None,
    timeout: float = 300,
    service: bool = False,
) -> Job:
    """Start one program, without a shell, and return its handle immediately:
    run("go", "test", "./...", cwd="cli"). It starts at once, at low priority.
    The timeout, in seconds and at most a day, counts wall time after the
    program starts.

    `env` adds to the kernel's environment. `stdin` is text or bytes to feed
    the program, a path to read, or another job, whose output streams in like
    a shell pipe (job.pipe(...) says the same). stderr joins stdout.

    Output stays on the handle: job.tail(lines=20) and job.head(lines=20) for
    its ends, output.read(job.id) for the retained whole. Jobs survive cell
    completion and each owns its process group. Only unfinished work counts
    against the concurrent quota; finished handles stay usable in `jobs` until
    newer ones displace them.

    A job that finishes with its result unread wakes the session by itself, so
    polling or trailing a handle is optional: leave it in a variable, end the
    cell, and the wake names the job when it lands. Awaiting the job, reading
    its result, or stopping it first means no wake.

    `nix` never copies a jj workspace into the store (a flake there is read
    from its commit), and `nix develop -c program ...` reuses a cached dev
    shell. `cargo` runs through mbx when it is installed, so every checkout
    shares compiled work; env={"ALBEDO_NO_MBX": "1"} runs plain cargo.

    Pass service=True for a program that is meant to keep running (a dev
    server, a file watcher): you are not waiting for it to finish, so it
    does not keep your prompt cache warm while you are idle.
    """
    check_timeout(timeout)
    if not (stdin is None or isinstance(stdin, (str, bytes, os.PathLike, Job))):
        raise TypeError(
            f"stdin is text, bytes, a path, or a job on this kernel, not {type(stdin).__name__}"
        )
    argv = albedo_shell.words((program, *args))
    script = albedo_shell.shell_script(argv)
    if script is not None:
        raise albedo_shell.refusal(f"`{os.path.basename(argv[0])} -c`", script=script)
    environment = albedo_shims.prepend(
        None
        if env is None
        else {**os.environ, **{str(k): str(v) for k, v in env.items()}}
    )
    directory = None if cwd is None else os.fsdecode(cwd)
    if os.sep not in argv[0]:
        found = shutil.which(argv[0], path=(environment or os.environ).get("PATH"))
        if found is None:
            if any(char.isspace() for char in argv[0]):
                raise albedo_shell.refusal(
                    "a whole command line as the program", script=argv[0]
                )
            raise FileNotFoundError(f"{argv[0]}: no such program on PATH")
    return start(
        argv, timeout, cwd=directory, env=environment, stdin=stdin, service=service
    )


def start(
    argv: list[str],
    timeout: float,
    *,
    cwd: str | None = None,
    env: dict[str, str] | None = None,
    stdin: Data | Job | None = None,
    traced: bool = True,
    service: bool = False,
) -> Job:
    """A job for argv as given, for run() and for plugins' own supervised work."""
    if len(active) >= ACTIVE_LIMIT:
        raise RuntimeError(f"{ACTIVE_LIMIT} jobs are active; await or stop one first")
    return Job(
        argv, timeout, cwd=cwd, env=env, stdin=stdin, traced=traced, service=service
    )


async def close() -> None:
    """Kernel shutdown: end every live group inside one shared deadline."""
    owned = list(active.values())
    # Never spawn a pending command just to shut it down. In-flight OS spawns,
    # however, must finish transferring ownership before the shared ladder.
    for job in owned:
        if not job._starting:
            job.spawning.cancel()
    await asyncio.gather(
        *(job._spawn() for job in owned if job.process is None), return_exceptions=True
    )
    live = [(job, group) for job in owned if (group := job.claim()) is not None]
    if not live:
        return
    endings = await albedo_proc.terminate(
        [group for _, group in live], SHUTDOWN_TERM, SHUTDOWN_KILL
    )
    for (job, _), ending in zip(live, endings):
        job.termination = ending
        release(job)
    failures = [ending.report() for ending in endings if not ending.gone]
    if failures:
        send({"type": "cleanup", "module": "run", "failures": failures})


def setup(api: PythonApi) -> dict[str, object]:
    global loop, capture_factory, preview_limit, jobs, active, retained, send
    global host, watch_output, forget_output
    loop, capture_factory, preview_limit, send = (
        api.loop,
        api.capture,
        api.preview,
        api.send,
    )
    host, watch_output, forget_output = api.host, api.watch_output, api.forget_output
    jobs, active, retained = {}, {}, OrderedDict()
    api.background_handle(Job)
    api.on_shutdown(close)
    return {"run": run, "jobs": jobs}
