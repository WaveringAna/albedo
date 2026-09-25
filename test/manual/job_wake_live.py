"""Opt-in live wake check against a real provider (deepseek by default).

Needs a real key: reads it from prime-agent's auth.json (or $ALBEDO_TEST_AUTH).
Not part of test.sh; run manually:
    python3 test/manual/job_wake_live.py

Boots the real daemon, submits one prompt that starts an unawaited background
job, then watches the event stream: the wake turn must arrive on its own while
nobody polls the python kernel, and the model must be able to read the job's
output from the notice it is given.
"""
import contextlib
import glob
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
AUTH_PATH = os.environ.get("ALBEDO_TEST_AUTH",
                           os.path.expanduser("~/.prime/agent/auth.json"))
AUTH = json.load(open(AUTH_PATH))
KEY = AUTH["deepseek"]["key"]
PROMPT = (
    "use the python tool to run exactly this cell and nothing else: "
    "job = bash(\"sleep 25; echo WAKE-DONE-42\") ; print(job.id) . "
    "then end your turn with a one-sentence confirmation. do not await the job, "
    "do not poll it, do not run anything else."
)


def main():
    with tempfile.TemporaryDirectory(prefix="albedo-live-wake-") as directory:
        home = Path(directory) / "home"
        workspace = Path(directory) / "workspace"
        home.mkdir(mode=0o700)
        workspace.mkdir()
        (home / "config.json").write_text(json.dumps({
            "active": "deepseek",
            "providers": {"deepseek": {
                "baseUrl": "https://api.deepseek.com/v1",
                "apiKey": KEY,
                "model": "deepseek-chat",
                "protocol": "chat_completions"}}}))
        env = dict(os.environ, HOME=str(Path(directory) / "user-home"),
                   ALBEDO_HOME=str(home), ALBEDO_IDLE_SECONDS="600")
        toolchain = ":".join(glob.glob("/nix/store/*gleam*/bin")
                             + glob.glob("/nix/store/*erlang*/bin"))
        if toolchain:
            env["PATH"] = toolchain + ":" + env["PATH"]
        first = subprocess.run([str(ROOT / "cli/bin/albedo"), "sessions"], cwd=ROOT,
                               env=env, text=True, capture_output=True, timeout=120)
        assert first.returncode == 0, first.stdout + first.stderr
        connection = json.loads((home / "daemon.json").read_text())
        base = f"http://127.0.0.1:{connection['port']}"
        headers = {"Authorization": "Bearer " + connection["token"],
                   "Content-Type": "application/json"}

        def api(path, body=None):
            request = urllib.request.Request(base + path, headers=headers,
                                             data=None if body is None else json.dumps(body).encode())
            return urllib.request.urlopen(request, timeout=60)

        created = json.loads(subprocess.run(
            [str(ROOT / "cli/bin/albedo"), "new", str(workspace)], cwd=ROOT, env=env,
            text=True, capture_output=True, timeout=120, check=True).stdout)
        session_id = created["session"]
        print("session", session_id)
        with api(f"/sessions/{session_id}/events", {"content": PROMPT}) as response:
            response.read()
        print("submitted; waiting for the first run to end")

        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            with api(f"/sessions/{session_id}/status") as response:
                status = json.load(response)
            if not status["running"]:
                break
            time.sleep(1)
        else:
            raise AssertionError("first run never settled: " + json.dumps(status))
        print("idle at", round(time.monotonic() % 100, 1), "s; job still running; now only listening")

        # Hold the stream open: no status polling, no python calls, nothing that
        # could carry the completion back except the wake itself.
        with api(f"/sessions/{session_id}/stream?after_seq=-1") as response:
            response.fp.raw._sock.settimeout(150)
            seen = []
            wake_at = None
            while True:
                line = response.readline()
                if not line:
                    break
                if not line.startswith(b"data: "):
                    continue
                page = json.loads(line[6:])
                seen.extend(page["events"])
                users = [e for e in page["events"] if e.get("type") == "user"
                         and "bash job finished" in e.get("text", "")]
                if users and wake_at is None:
                    wake_at = time.monotonic()
                    print("WAKE TURN ARRIVED:")
                    print(" ", users[0]["source"], "|", users[0]["text"][:220])
                messages = [e for e in page["events"] if e.get("type") == "message"]
                if wake_at is not None and messages:
                    print("MODEL REPLIED TO THE WAKE:")
                    print(" ", messages[0]["text"][:600])
                    break
                if time.monotonic() > wake_at + 120 if wake_at else time.monotonic() > deadline + 150:
                    break
        assert wake_at is not None, "no wake arrived; events: " + json.dumps(
            [e.get("type") for e in seen])
        with contextlib.suppress(Exception):
            api("/shutdown", {}).close()
        print("PASS: the session woke itself and the model answered the wake")


if __name__ == "__main__":
    main()
