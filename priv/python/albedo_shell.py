"""Shell lines read as run() calls, and the guard that keeps cells on run().

Cells start programs with run(program, *args): no shell, supervised, traced.
A shell line or a raw process API from a cell is refused with the run() call
it means when the line is simple enough to read, so the refusal teaches by
example. A time.sleep of a second or more is refused too: it blocks the whole
kernel, and the refusal says to run the work async or to wait on purpose. This is guidance, not a sandbox: libraries and plugins still spawn.
"""

from __future__ import annotations

from collections.abc import Sequence
import os
import re
import shlex
import sys
import sysconfig

SHELLS = {"sh", "bash", "zsh", "dash", "ksh", "fish", "nu"}
CELL_PREFIX = "<albedo:"  # the filename every cell compiles under
BLOCKING_SLEEP = 1.0  # seconds; a shorter time.sleep from a cell is let through
SPAWN_EVENTS = {
    "subprocess.Popen",
    "os.system",
    "os.posix_spawn",
    "os.exec",
    "os.spawn",
}
# stdlib frames sit between a cell and the spawn it asked for; site-packages do not
STDLIB = tuple({sysconfig.get_paths()[key] for key in ("stdlib", "platstdlib")})
HINTS = (
    "cd dir && … → cwd=, NAME=value → env=, a | b → run(a…).pipe(b…), "
    "| tail -n N → .tail(lines=N), | head -n N → .head(lines=N), 2>&1 is implied, "
    "and chains, loops, and globs are Python over the job's output."
)


class Refused(PermissionError):
    """A shell or raw process API where run() belongs."""


def shell_script(argv: Sequence[str]) -> str | None:
    """The script of `sh -c script` and its spellings (`bash -lc`), else None."""
    if not argv or os.path.basename(argv[0]) not in SHELLS:
        return None
    for index, arg in enumerate(argv[1:], 1):
        if arg.startswith("--"):
            continue  # --norc, --login
        if not arg.startswith("-"):
            return None
        if "c" in arg[1:]:
            return argv[index + 1] if index + 1 < len(argv) else ""
    return None


def words(items: Sequence[object]) -> list[str]:
    """run()'s arguments as argv: text, paths, and numbers."""
    argv = []
    for item in items:
        if isinstance(item, (str, bytes, os.PathLike)):
            argv.append(os.fsdecode(item))
        elif isinstance(item, (int, float)) and not isinstance(item, bool):
            argv.append(str(item))
        else:
            raise TypeError(
                f"run() arguments are text, paths, or numbers, not {type(item).__name__}"
            )
    return argv


def call(
    argv: Sequence[str], cwd: str | None = None, env: dict[str, str] | None = None
) -> str:
    """argv as the run() call that starts it."""
    parts = [repr(arg) for arg in argv]
    if cwd:
        parts.append(f"cwd={cwd!r}")
    if env:
        parts.append(f"env={env!r}")
    return f"run({', '.join(parts)})"


def _unquoted(script: str) -> str:
    """script with quoted text blanked, so shell syntax outside quotes shows."""
    out, quote, escaped = [], "", False
    for char in script:
        if escaped:
            out.append(" ")
            escaped = False
        elif char == "\\" and quote != "'":
            out.append(" ")
            escaped = True
        elif quote:
            out.append(" ")
            quote = "" if char == quote else quote
        elif char in "'\"":
            out.append(" ")
            quote = char
        else:
            out.append(char)
    return "".join(out)


_LIMIT = re.compile(r"^(head|tail)(?:\s+-n\s*(\d+)|\s+-(\d+))?$")


def _split(text: str, plain: str, separator: str) -> list[tuple[str, str]]:
    """text, and its unquoted form, cut where separator stands outside quotes."""
    parts, start = [], 0
    for match in re.finditer(separator, plain):
        parts.append((text[start : match.start()], plain[start : match.start()]))
        start = match.end()
    parts.append((text[start:], plain[start:]))
    return [part for part in parts if part[0].strip()]


def _stage(text: str) -> tuple[list[str], dict[str, str]]:
    """One pipeline stage's argv and the NAME=value words before it."""
    words, env = shlex.split(text), {}
    while words and re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", words[0]):
        name, _, value = words.pop(0).partition("=")
        env[name] = value
    if not words:
        raise ValueError("a stage with no program")
    return words, env


def translate(script: str) -> str | None:
    """The run() code a simple shell line means, or None when it does more than
    start programs: `cd cli && go test ./... | tail -5` is
    `job = run('go', 'test', './...', cwd='cli')`, `await job`, then
    `job.tail(lines=5)`, and each other `|` is a .pipe(...)."""
    plain = _unquoted(script)
    for match in re.finditer(r"2>&1", plain):  # stderr joins stdout anyway
        script = script[: match.start()] + "    " + script[match.end() :]
    plain = plain.replace("2>&1", "    ")
    if (
        re.search(r"[$`*?<>(){}&]|(?:^|\s)~", plain.replace("&&", "  "))
        or "||" in plain
    ):
        return None
    cwd, stages = None, None
    try:
        for text, part in _split(script, plain, r"&&|;|\n"):
            piped = [stage for stage, _ in _split(text, part, r"\|")]
            words = shlex.split(piped[0])
            if words[:1] == ["cd"] and len(words) == 2 and stages is None:
                cwd = words[1]
            elif stages is None:
                stages = piped
            else:
                return None
        if stages is None:
            return None
        limit = _LIMIT.match(stages[-1].strip()) if len(stages) > 1 else None
        if limit is not None:
            stages = stages[:-1]
        calls = []
        for index, stage in enumerate(stages):
            words, env = _stage(stage)
            inner = shell_script(words)
            if inner is not None:  # a shell inside the line: read what it runs
                return (
                    translate(inner)
                    if len(stages) == 1 and limit is None and not env
                    else None
                )
            call_text = call(words, cwd, env)
            calls.append(
                call_text if index == 0 else ".pipe" + call_text.removeprefix("run")
            )
    except ValueError:
        return None
    read = (
        "tail()"
        if limit is None
        else f"{limit.group(1)}(lines={limit.group(2) or limit.group(3) or 10})"
    )
    return f"job = {''.join(calls)}\nawait job\njob.{read}"


def refusal(
    what: str,
    script: str | None = None,
    argv: Sequence[str] | None = None,
    cwd: str | None = None,
) -> Refused:
    """Why `what` is refused, with the run() call it means when there is one."""
    suggestion = (
        translate(script)
        if script is not None
        else (f"job = await {call(argv, cwd)}\njob.tail()" if argv else None)
    )
    if suggestion:
        return Refused(
            f"{what} is refused here; run() starts programs without a shell. this one is:\n"
            + "".join(f"    {line}\n" for line in suggestion.splitlines())
        )
    return Refused(
        f"{what} is refused here; run() starts one program without a shell: "
        f"run('git', 'status', cwd='cli'). {HINTS}"
    )


installed = False


def _from_cell(skip: int) -> bool:
    """Whether the spawn under way was asked for by cell code itself, rather
    than by a plugin or library the cell called. skip counts the audit hook's
    own frames above the spawning call."""
    try:
        frame = sys._getframe(skip)
    except ValueError:
        return False
    while frame is not None:
        name = frame.f_code.co_filename
        if name.startswith(CELL_PREFIX):
            return True
        stdlib = name.startswith("<frozen") or (
            name.startswith(STDLIB) and "-packages" not in name
        )
        if not stdlib:
            return False
        frame = frame.f_back
    return False


def _strings(args: object) -> list[str]:
    if isinstance(args, (str, bytes, os.PathLike)):
        return [os.fsdecode(args)]
    if isinstance(args, (list, tuple)):
        return [
            os.fsdecode(arg) if isinstance(arg, (str, bytes, os.PathLike)) else str(arg)
            for arg in args
        ]
    return []


def sleep_refusal(seconds: float) -> Refused:
    """Why a cell may not block the kernel with time.sleep."""
    return Refused(
        f"time.sleep({seconds:g}) is refused here: it blocks the whole kernel, so nothing "
        "else in this session runs while it waits. Start the work with run() and do other "
        "useful work while it runs; its completion wakes you. If there is nothing else to "
        "do, give the user a status report first, then wait with "
        f"`await asyncio.sleep({seconds:g})`."
    )


def guard(event: str, args: tuple[object, ...]) -> None:
    """Audit hook: a cell that spawns through subprocess or os gets run() instead,
    and one that sleeps the kernel is told to run async work or wait explicitly."""
    if event == "time.sleep":
        seconds = args[0]
        if (
            isinstance(seconds, (int, float))
            and seconds >= BLOCKING_SLEEP
            and _from_cell(skip=2)
        ):
            raise sleep_refusal(seconds)
        return
    if event not in SPAWN_EVENTS or not _from_cell(skip=2):
        return
    if event == "os.system":
        raise refusal("os.system", script=_strings(args[0])[0])
    argv = _strings(args[2] if event == "os.spawn" else args[1])
    cwd = (
        _strings(args[2])[0]
        if event == "subprocess.Popen" and args[2] is not None
        else None
    )
    script = shell_script(argv)
    what = "subprocess" if event == "subprocess.Popen" else event
    raise (
        refusal(what, script=script)
        if script is not None
        else refusal(what, argv=argv, cwd=cwd)
    )


def install() -> None:
    global installed
    if not installed:
        installed = True
        sys.addaudithook(guard)
