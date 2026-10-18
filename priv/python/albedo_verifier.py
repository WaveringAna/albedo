"""Runs a child agent's verifier command in its own process group and exits 0
when the command passes, or 1 with bounded failure detail on stdout."""

from __future__ import annotations

import json
import os
import signal
import subprocess
import sys
import tempfile

import albedo_proc

OUTPUT_LIMIT = 8192
TIMEOUT = 300.0


def tail_excerpt(text: str) -> str:
    stripped = text.strip()
    if len(stripped) <= 4000:
        return stripped
    return "...\n" + stripped[-4000:]


def main() -> int:
    request = json.loads(sys.stdin.readline())
    command = str(request["command"])
    cwd = request.get("cwd")
    cwd = cwd if isinstance(cwd, str) and os.path.isdir(cwd) else None
    with tempfile.TemporaryFile() as stdin, tempfile.TemporaryFile() as out:
        process = subprocess.Popen(
            command,
            shell=True,
            cwd=cwd,
            stdin=stdin,
            stdout=out,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        group = albedo_proc.Group(process.pid, albedo_proc.leader_token(process.pid))
        timed_out = False
        try:
            process.wait(TIMEOUT)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            albedo_proc.send_signal(group, signal.SIGKILL)
            process.wait()
        out.seek(0)
        raw = out.read(OUTPUT_LIMIT * 2).decode(errors="replace")
        excerpt = tail_excerpt(raw)
        if timed_out:
            detail = f"verifier `{command}` timed out after {TIMEOUT:g}s"
            if excerpt:
                detail += f":\n{excerpt}"
            print(detail)
            return 1
        if process.returncode == 0:
            return 0
        detail = f"verifier `{command}` failed (exit {process.returncode})"
        if excerpt:
            detail += f":\n{excerpt}"
        print(detail)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
