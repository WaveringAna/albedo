"""One SSH host answers the session's remote work.

A command crosses the wire as `ssh <target> <shlex-quoted script>`: the local
ssh process is the whole lifetime of the call, so a deadline ends it from this
side while a surviving remote descendant learns of the loss only when its
pipes close. File contents never travel as shell text -- writes go as base64
and reads come back as bytes -- and a path under the local workspace maps onto
the remote cwd, the one seam between two filesystems.

The target resolves per call: an explicit `host=` argument, then the value
`ssh.configure` stored, then `$ALBEDO_SSH`, then the `ssh` section of
extensions.json. A bare `user@host` asks the remote for its `pwd` once.
"""
from __future__ import annotations

import base64
import json
import os
import shlex
import subprocess

CONNECT_TIMEOUT = 10  # seconds before an unreachable host gives up
DEFAULT_TIMEOUT = 120  # seconds before a running command loses its ssh process

local_cwd: str | None = None
configured: dict[str, str] = {}


class SshError(RuntimeError):
    """A remote operation failed; stderr carries whatever the host said."""


class Ssh:
    """Namespace object bound into the kernel as `ssh`."""

    @staticmethod
    def configure(host: str, remote_cwd: str | None = None) -> dict[str, str]:
        """Resolve `user@host[:/path]` once and keep it for later calls."""
        target = parse_target(host)
        if target["remote_cwd"] is None and remote_cwd is None:
            target["remote_cwd"] = _exec(
                target["host"], "pwd", DEFAULT_TIMEOUT
            ).stdout.strip()
        elif remote_cwd is not None:
            target["remote_cwd"] = remote_cwd
        configured.clear()
        configured.update(target)
        return resolved()

    @staticmethod
    def run(
        command: str, host: str | None = None, timeout: float | None = None
    ) -> dict[str, object]:
        """Execute a command remotely; the exit code is data, not an error."""
        target = resolve(host)
        script = command
        if target["remote_cwd"]:
            script = f"cd {shlex.quote(target['remote_cwd'])} && {command}"
        done = _exec(target["host"], script, timeout or DEFAULT_TIMEOUT)
        return {
            "command": command,
            "host": target["host"],
            "exit_code": done.returncode,
            "stdout": done.stdout,
            "stderr": done.stderr,
        }

    @staticmethod
    def read(path: str, host: str | None = None, timeout: float | None = None) -> str:
        """Return a remote file's text; a missing or unreadable file raises."""
        target = resolve(host)
        done = _exec(
            target["host"], f"cat {shlex.quote(to_remote(target, path))}",
            timeout or DEFAULT_TIMEOUT,
        )
        if done.returncode != 0:
            raise SshError(f"SSH failed ({done.returncode}): {done.stderr}")
        return done.stdout

    @staticmethod
    def write(
        path: str, content: str, host: str | None = None,
        timeout: float | None = None,
    ) -> None:
        """Replace a remote file's contents; bytes travel base64-encoded."""
        target = resolve(host)
        encoded = base64.b64encode(content.encode()).decode()
        done = _exec(
            target["host"],
            f"printf '%s' {shlex.quote(encoded)} | base64 -d >"
            f" {shlex.quote(to_remote(target, path))}",
            timeout or DEFAULT_TIMEOUT,
        )
        if done.returncode != 0:
            raise SshError(f"SSH failed ({done.returncode}): {done.stderr}")


ssh = Ssh()


def parse_target(arg: str) -> dict[str, str | None]:
    """Split `user@host[:/path]`; a colon not followed by a path stays in the host."""
    head, separator, tail = arg.partition(":")
    remote_cwd = tail if separator and tail.startswith("/") else None
    return {"host": arg if remote_cwd is None else head, "remote_cwd": remote_cwd}


def resolve(host: str | None) -> dict[str, str | None]:
    """The target this call runs against, or a misuse error naming every source."""
    if host is None and configured:
        return dict(configured)
    if host is None:
        host = os.environ.get("ALBEDO_SSH") or _settings().get("host")
    if host is None:
        raise SshError(
            "no ssh target: pass host=, call ssh.configure(), set $ALBEDO_SSH, "
            "or add an \"ssh\" section to extensions.json"
        )
    target = parse_target(host)
    if target["remote_cwd"] is None:
        target["remote_cwd"] = _settings().get("remoteCwd")
    return target


def resolved() -> dict[str, str]:
    """The stored target with every field known; configure() just answered for it."""
    return {"host": configured["host"], "remoteCwd": configured["remote_cwd"] or ""}


def to_remote(target: dict[str, str | None], path: str) -> str:
    """The remote spelling of a workspace path; anything else passes through."""
    remote_cwd = target.get("remote_cwd")
    if local_cwd and remote_cwd:
        return path.replace(local_cwd, remote_cwd, 1)
    return path


def _settings() -> dict[str, str]:
    """The `ssh` section of extensions.json, or nothing; malformed JSON raises."""
    home = os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo")
    try:
        with open(os.path.join(home, "extensions.json"), "rb") as handle:
            sections = json.load(handle)
    except FileNotFoundError:
        return {}
    section = sections.get("ssh") if isinstance(sections, dict) else None
    if section is None:
        return {}
    if not isinstance(section, dict):
        raise SshError("extensions.json ssh section must be an object")
    return {key: section[key] for key in ("host", "remoteCwd") if key in section}


class _Done:
    """What one ssh process answered, decoded leniently for text use."""

    def __init__(self, returncode: int, stdout: bytes, stderr: bytes) -> None:
        self.returncode = returncode
        self.stdout = stdout.decode(errors="replace")
        self.stderr = stderr.decode(errors="replace")


def _exec(target: str, script: str, timeout: float) -> _Done:
    """Run one ssh process to completion; its stderr names connection failures."""
    try:
        done = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", "-o", f"ConnectTimeout={CONNECT_TIMEOUT}",
             target, script],
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as expired:
        raise SshError(
            f"SSH command lost its process after {timeout:g}s: {script}"
        ) from expired
    except FileNotFoundError as missing:
        raise SshError(f"ssh not available: {missing}") from missing
    return _Done(done.returncode, done.stdout, done.stderr)


def setup(api: object) -> dict[str, object]:
    global local_cwd
    del api
    local_cwd = os.getcwd()
    return {"ssh": ssh}
