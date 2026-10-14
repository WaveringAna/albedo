"""Runs the Claude Code command hooks hooks.json configures for one event
and prints their merged verdict as one JSON line (robot-docs/hooks.md). The
hooks extension starts one per event, with the request on stdin."""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import albedo_proc

CONTEXT_LIMIT = 10_000
OUTPUT_LIMIT = 1 << 20


def verdict(**fields: object) -> dict:
    return {
        "block": None,
        "halt": None,
        "arguments": None,
        "context": [],
        "notes": [],
    } | fields


def merge(into: dict, extra: dict) -> None:
    for key in ("block", "halt", "arguments"):
        into[key] = into[key] if into[key] is not None else extra[key]
    for key in ("context", "notes"):
        into[key] += extra[key]


def matches(matcher: str, subject: str) -> bool:
    return matcher in ("", "*") or re.search(matcher, subject) is not None


def execute(command: str, payload: dict, timeout: float) -> tuple[int, str, str]:
    """One command in its own process group, the payload on stdin; output
    goes to files, so a backgrounded child holding a pipe cannot hang us."""
    cwd = payload["cwd"] if os.path.isdir(payload["cwd"]) else None
    with tempfile.TemporaryFile() as stdin, tempfile.TemporaryFile() as out:
        with tempfile.TemporaryFile() as err:
            stdin.write(json.dumps(payload).encode())
            stdin.seek(0)
            process = subprocess.Popen(
                command,
                shell=True,
                cwd=cwd,
                stdin=stdin,
                stdout=out,
                stderr=err,
                start_new_session=True,
            )
            group = albedo_proc.Group(
                process.pid, albedo_proc.leader_token(process.pid)
            )
            try:
                process.wait(timeout)
            except subprocess.TimeoutExpired:
                raise TimeoutError(f"timed out after {timeout:g}s") from None
            finally:
                albedo_proc.send_signal(group, signal.SIGKILL)
                process.wait()
            out.seek(0)
            err.seek(0)
            text = [f.read(OUTPUT_LIMIT).decode(errors="replace") for f in (out, err)]
            return process.returncode, text[0], text[1]


def judge(definition: dict, payload: dict) -> dict:
    """What one command said, in the shape the hooks extension decodes. A
    command that fails or answers nonsense fails open with a note."""
    event = payload["hook_event_name"]
    try:
        command, timeout = definition.get("command"), definition.get("timeout", 600)
        if definition.get("type") != "command" or not isinstance(command, str):
            raise ValueError("only command hooks are supported")
        if type(timeout) not in (int, float) or not 0 < timeout < float("inf"):
            raise ValueError("timeout must be a positive number of seconds")
        status, stdout, stderr = execute(command, payload, timeout)
        if status == 2:
            return verdict(block=stderr.strip() or "blocked by a hook")
        if status != 0:
            raise ValueError(f"exited {status}: {stderr.strip()}")
        if not stdout.strip():
            return verdict()
        try:
            output = json.loads(stdout)
        except ValueError:
            if event != "UserPromptSubmit":
                raise ValueError("invalid hook JSON") from None
            output = {"hookSpecificOutput": {"additionalContext": stdout.strip()}}
        return answer(event, output)
    except Exception as error:
        return verdict(
            notes=[f"{event} hook {definition.get('command')!r} failed open: {error}"]
        )


def answer(event: str, output: object) -> dict:
    if not isinstance(output, dict):
        raise ValueError("hook output must be a JSON object")
    specific = output.get("hookSpecificOutput") or {}
    result = verdict()
    if output.get("continue") is False:
        result["halt"] = str(output.get("stopReason") or "stopped by a hook")
    if output.get("decision") == "block":
        result["block"] = str(output.get("reason") or "blocked by a hook")
    if specific.get("permissionDecision") == "deny":
        result["block"] = str(specific.get("permissionDecisionReason") or "denied")
    if isinstance(specific.get("updatedInput"), dict):
        result["arguments"] = json.dumps(specific["updatedInput"])
    if context := str(specific.get("additionalContext") or ""):
        if len(context) > CONTEXT_LIMIT:
            context = context[: CONTEXT_LIMIT - 12] + "\n[truncated]"
        result["context"] = [f"[{event} hook] {context}"]
    if output.get("systemMessage"):
        result["notes"] = [str(output["systemMessage"])]
    return result


def main() -> None:
    request = json.loads(sys.stdin.readline())
    event, payload = request["event"], request["input"]
    result = verdict()
    try:
        config = json.loads(Path(request["config"]).read_text())
        definitions = [
            definition
            for group in config["hooks"].get(event, [])
            if matches(group.get("matcher", ""), request["subject"])
            for definition in group["hooks"]
        ]
    except Exception as error:
        result["notes"].append(f"{request['config']} failed open: {error!r}")
        definitions = []
    with ThreadPoolExecutor(max_workers=8) as pool:
        for extra in pool.map(lambda item: judge(item, payload), definitions):
            merge(result, extra)
    # These blocks reach the model as input of their own, not as a refusal.
    if result["block"] is not None and event in ("PostToolUse", "Stop"):
        result["block"] = f"[{event} hook] {result['block']}"
    print(json.dumps(result))


if __name__ == "__main__":
    main()
