"""Explicit Chrome process ownership; no CLI, driver, or second event loop."""

from __future__ import annotations

import asyncio
import atexit
from collections.abc import Awaitable, Sequence
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
from typing import BinaryIO, TYPE_CHECKING, TypeVar

from .errors import LaunchError
from .transport import positive

if TYPE_CHECKING:
    from .session import Browser

_T = TypeVar("_T")
_MARKER = ".albedo-browser-profile"
_LOCK = ".albedo-browser-launch.lock"
# One strong reference per live owned process, including deliberately disconnected ones.
# A normal interpreter exit gets a best-effort cleanup. SIGKILL cannot run atexit.
_LIVE: set[OwnedChrome] = set()


async def _finish_cleanup(operation: Awaitable[_T]) -> _T:
    """Finish bounded cleanup before propagating a caller's (even repeated) cancel."""
    task = asyncio.ensure_future(operation)
    interrupted = False
    while True:
        try:
            result = await asyncio.shield(task)
            break
        except asyncio.CancelledError:
            if task.cancelled():
                raise
            interrupted = True
            if task.done():
                # Retrieve exceptions too, rather than abandoning a finished task.
                result = task.result()
                break
    if interrupted:
        raise asyncio.CancelledError
    return result


def _executable(requested: str | os.PathLike[str] | None) -> str:
    explicit = (
        requested
        or os.environ.get("ALBEDO_BROWSER_EXECUTABLE")
        or os.environ.get("PRIME_BROWSER_EXECUTABLE")
        or os.environ.get("CHROME_PATH")
    )
    if explicit:
        candidate = os.path.expanduser(os.fspath(explicit))
        found = shutil.which(candidate)
        if found:
            return found
        raise LaunchError(
            "Chrome executable was not found or is not executable.",
            reason="executable_not_found",
            executable=candidate,
            recovery='Pass executable="/path/to/chrome" or install Chrome/Chromium in the kernel environment.',
        )
    for name in (
        "chromium",
        "chromium-browser",
        "google-chrome",
        "google-chrome-stable",
        "chrome",
    ):
        found = shutil.which(name)
        if found:
            return found
    candidates: list[Path] = []
    for root in (Path("/Applications"), Path.home() / "Applications"):
        for app, binary in (
            ("Google Chrome", "Google Chrome"),
            ("Chromium", "Chromium"),
            ("Google Chrome for Testing", "Google Chrome for Testing"),
        ):
            candidates.append(root / f"{app}.app/Contents/MacOS" / binary)
    for variable in ("PROGRAMFILES", "PROGRAMFILES(X86)", "LOCALAPPDATA"):
        root = os.environ.get(variable)
        if root:
            candidates.extend(
                (
                    Path(root) / "Google/Chrome/Application/chrome.exe",
                    Path(root) / "Chromium/Application/chrome.exe",
                )
            )
    for path in candidates:
        if path.is_file() and os.access(path, os.X_OK):
            return str(path)
    raise LaunchError(
        "Chrome/Chromium was not found. spawn() does not download a browser.",
        reason="executable_not_found",
        recovery='Install Chrome/Chromium, or pass executable="/path/to/chrome".',
    )


def _extra_args(args: Sequence[str]) -> list[str]:
    if isinstance(args, (str, bytes)):
        raise ValueError(
            "args must be a sequence of separate --flag strings, not a shell command"
        )
    reserved = {
        "--user-data-dir",
        "--profile-directory",
        "--headless",
        "--no-sandbox",
        "--disable-setuid-sandbox",
    }
    result = []
    for arg in args:
        if (
            not isinstance(arg, str)
            or not arg.startswith("--")
            or arg == "--"
            or "\x00" in arg
        ):
            raise ValueError(
                "Each extra argument must be a separate --flag string; no positional URLs"
            )
        key = arg.split("=", 1)[0]
        if key in reserved or key.startswith("--remote-debugging"):
            raise ValueError(
                f"{key} is managed by spawn(); use its named options instead"
            )
        result.append(arg)
    return result


class OwnedChrome:
    """Internal lifecycle object; Browser delegates to it only after successful spawn."""

    def __init__(self, profile: str | os.PathLike[str] | None) -> None:
        self.temporary = profile is None
        self.profile = (
            Path(tempfile.mkdtemp(prefix="prime-browser-"))
            if profile is None
            else Path(profile).expanduser().resolve()
        )
        self.process: subprocess.Popen[bytes] | None = None
        self.log: BinaryIO | None = None
        self._lock_fd: int | None = None
        self._released = False
        try:
            self.profile.mkdir(parents=True, exist_ok=True, mode=0o700)
            # O_EXCL closes the race between two spawn() calls using the same profile.
            try:
                self._lock_fd = os.open(
                    self.profile / _LOCK, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600
                )
                os.write(self._lock_fd, f"kernel_pid={os.getpid()}\n".encode())
            except FileExistsError as exc:
                raise LaunchError(
                    "This profile is already reserved by another spawn().",
                    reason="profile_in_use",
                    profile=str(self.profile),
                    recovery="Use a different profile, or close its owning Browser. Do not delete a live lock.",
                ) from exc
            marker = self.profile / _MARKER
            if not marker.is_file() and any(
                p.name != _LOCK for p in self.profile.iterdir()
            ):
                raise LaunchError(
                    "Refusing a nonempty profile not created for this skill.",
                    reason="unsafe_profile",
                    profile=str(self.profile),
                    recovery="Use a new empty directory, not your normal browser profile.",
                )
            # lexists notices dangling singleton symlinks too: don't guess whether a
            # previous Chrome crashed, or attach to somebody else's running process.
            if any(
                os.path.lexists(self.profile / name)
                for name in ("SingletonLock", "SingletonSocket")
            ):
                raise LaunchError(
                    "Chrome has a singleton lock in this profile.",
                    reason="profile_in_use",
                    profile=str(self.profile),
                )
            marker.touch(mode=0o600, exist_ok=True)
            # After acquiring our exclusive lock, remove only stale discovery metadata.
            (self.profile / "DevToolsActivePort").unlink(missing_ok=True)
            self.log = tempfile.TemporaryFile(mode="w+b", prefix="prime-browser-log-")
        except BaseException:
            self._release()
            raise

    def start(
        self, executable: str, *, headless: bool, sandbox: bool, args: list[str]
    ) -> None:
        command = [
            executable,
            f"--user-data-dir={self.profile}",
            "--remote-debugging-address=127.0.0.1",
            "--remote-debugging-port=0",
            "--no-first-run",
            "--no-default-browser-check",
        ]
        if headless:
            command.extend(["--headless=new", "--disable-dev-shm-usage"])
        if not sandbox:
            command.append("--no-sandbox")
        command.extend(args)
        command.append("about:blank")
        # Intentionally no await between process creation and taking ownership. A
        # cancelled create_subprocess_exec() can otherwise lose its returned handle.
        # Output goes to a temporary file: no pipe backpressure or kernel-stdout noise.
        self.process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=self.log,
            stderr=self.log,
            start_new_session=(os.name == "posix"),
        )
        _LIVE.add(self)

    async def endpoint(self) -> str:
        assert self.process is not None
        active = self.profile / "DevToolsActivePort"
        while True:
            code = self.process.poll()
            if code is not None:
                raise LaunchError(
                    "Chrome exited before CDP became ready.",
                    reason="process_exited",
                    returncode=code,
                )
            try:
                with active.open("rb") as stream:
                    lines = stream.read(4096).decode("ascii").splitlines()
                if len(lines) >= 2 and lines[0].isdigit():
                    port = int(lines[0])
                    path = lines[1]
                    if 1 <= port <= 65535 and re.fullmatch(
                        r"/devtools/browser/[a-zA-Z0-9._-]+", path
                    ):
                        return f"ws://127.0.0.1:{port}{path}"
            except (FileNotFoundError, UnicodeError):
                pass  # The file may not exist yet, or Chrome may still be writing it.
            await asyncio.sleep(0.05)

    def stderr_tail(self) -> str:
        if self.log is None or self.log.closed:
            return ""
        self.log.seek(0, os.SEEK_END)
        self.log.seek(max(0, self.log.tell() - 8192))
        return self.log.read(8192).decode("utf-8", errors="replace")

    async def wait(self, seconds: float) -> bool:
        if self.process is None:
            return True
        deadline = asyncio.get_running_loop().time() + seconds
        while self.process.poll() is None:
            if asyncio.get_running_loop().time() >= deadline:
                return False
            await asyncio.sleep(0.05)
        return True

    def _signal(self, *, kill: bool) -> None:
        if self.process is None or self.process.poll() is not None:
            return
        try:
            if os.name == "posix":
                # Chrome children may inherit its process group. Never signal the
                # kernel's group: start_new_session=True gave this launch its own.
                os.killpg(self.process.pid, signal.SIGKILL if kill else signal.SIGTERM)
            elif kill:
                self.process.kill()
            else:
                self.process.terminate()
        except ProcessLookupError:
            pass

    def _release(self) -> None:
        if self._released:
            return
        if self.process is not None and self.process.poll() is None:
            raise LaunchError(
                "Chrome is still alive; keeping its profile and lock.",
                reason="cleanup_failed",
                pid=self.process.pid,
                profile=str(self.profile),
            )
        if self.log is not None:
            self.log.close()
        if self._lock_fd is not None:
            os.close(self._lock_fd)
            self._lock_fd = None
            (self.profile / _LOCK).unlink(missing_ok=True)
        if self.temporary:
            try:
                shutil.rmtree(self.profile)
            except FileNotFoundError:
                pass
        self._released = True
        _LIVE.discard(self)

    async def stop(self) -> None:
        if self._released:
            return
        self._signal(kill=False)
        if not await self.wait(3):
            self._signal(kill=True)
            if not await self.wait(3):
                raise LaunchError(
                    "Chrome did not exit after termination.",
                    reason="cleanup_failed",
                    pid=self.process.pid if self.process else None,
                    profile=str(self.profile),
                )
        # Chrome's children may finish touching the profile just after the parent
        # exits. Retry only directory removal, not process creation or browser input.
        for attempt in range(5):
            try:
                self._release()
                return
            except OSError as exc:
                if attempt == 4:
                    raise LaunchError(
                        "Chrome stopped, but profile cleanup failed.",
                        reason="cleanup_failed",
                        profile=str(self.profile),
                    ) from exc
                await asyncio.sleep(0.1)

    def exit_cleanup(self) -> None:
        """Synchronous fallback for normal Python exit, not a hard-kill guarantee."""
        try:
            self._signal(kill=False)
            if self.process is not None:
                try:
                    self.process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    self._signal(kill=True)
                    self.process.wait(timeout=1)
            self._release()
        except Exception:
            pass


def _cleanup_at_exit() -> None:
    for owner in list(_LIVE):
        owner.exit_cleanup()


atexit.register(_cleanup_at_exit)


async def spawn(
    *,
    executable: str | os.PathLike[str] | None = None,
    headless: bool = True,
    profile: str | os.PathLike[str] | None = None,
    args: Sequence[str] = (),
    sandbox: bool = True,
    timeout: float = 20,
    max_message_bytes: int = 16 * 1024 * 1024,
) -> Browser:
    """Start a dedicated Chrome/Chromium and return a connected, process-owning Browser.

    Auto-detects an installed executable. Uses headless mode, a temporary profile,
    loopback CDP and an OS-assigned port by default; never downloads a browser or
    silently disables its sandbox. A supplied profile must be empty or previously
    created by this skill and is preserved on close. ``Browser.close()`` or
    ``async with await spawn()`` stops owned Chrome and removes temporary data.
    ``disconnect()`` deliberately leaves it running until close or normal exit.

    timeout bounds startup and CDP initialization; bounded cleanup may take extra
    time. Exceptions include a diagnostic log tail. Cancelled startup is cleaned
    up before cancellation propagates; actions are never retried.
    """
    from .session import connect

    positive(timeout, "timeout")
    if not isinstance(headless, bool) or not isinstance(sandbox, bool):
        raise ValueError("headless and sandbox must be booleans")
    if (
        isinstance(max_message_bytes, bool)
        or not isinstance(max_message_bytes, int)
        or max_message_bytes < 1024
    ):
        raise ValueError("max_message_bytes must be an integer of at least 1024")
    extra = _extra_args(args)
    binary = _executable(executable)
    if sandbox and hasattr(os, "geteuid") and os.geteuid() == 0:
        raise LaunchError(
            "Chrome cannot use its sandbox as root. Run the kernel as an unprivileged user.",
            reason="root_requires_opt_in",
            recovery="Only in an externally isolated disposable container, explicitly use sandbox=False.",
        )
    owner = OwnedChrome(profile)
    browser = None
    try:
        async with asyncio.timeout(timeout):
            owner.start(binary, headless=headless, sandbox=sandbox, args=extra)
            endpoint = await owner.endpoint()
            browser = await connect(endpoint, max_message_bytes=max_message_bytes)
            if owner.process is None or owner.process.poll() is not None:
                raise LaunchError(
                    "Chrome exited during CDP initialization.", reason="process_exited"
                )
            browser._owner = owner
            return browser
    except BaseException as exc:
        tail = owner.stderr_tail()
        code = owner.process.poll() if owner.process else None

        async def cleanup() -> None:
            try:
                if browser is not None:
                    await browser.disconnect()
            finally:
                await owner.stop()

        try:
            await _finish_cleanup(cleanup())
        except asyncio.CancelledError:
            raise
        except Exception as cleanup_error:
            exc.add_note(
                f"Cleanup also failed: {cleanup_error}; profile={owner.profile}"
            )
        if isinstance(exc, (asyncio.CancelledError, KeyboardInterrupt, SystemExit)):
            raise
        if isinstance(exc, LaunchError):
            exc.details.update(
                stderr_tail=tail, executable=binary, profile=str(owner.profile)
            )
            raise
        raise LaunchError(
            "Chrome startup timed out."
            if isinstance(exc, TimeoutError)
            else "Chrome startup failed.",
            reason="startup_timeout"
            if isinstance(exc, TimeoutError)
            else "startup_failed",
            executable=binary,
            profile=str(owner.profile),
            returncode=code,
            stderr_tail=tail,
            cause=type(exc).__name__,
            timeout=timeout,
        ) from exc


async def cleanup_all() -> None:
    tasks = [chrome.stop() for chrome in list(_LIVE)]
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)
