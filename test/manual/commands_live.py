"""Opt-in live e2e for the session command surface against a real provider
(deepseek by default): a real model drives the typed `commands` bindings
through the real tool loop.

Needs a real key: reads the deepseek profile's key from albedo's creds.json
(or the file $ALBEDO_TEST_CREDS names).
Not part of test.sh; run manually:
    python3 test/manual/commands_live.py

Proves, with no fixtures in the path: the minted typed methods and their
help/signature, the model-mode read of /model, the model-mode refusal to
switch, the skills command with exact argument round-trip, the served command
catalog, and a user-mode model switch that the next real request actually
uses.
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
CREDS_PATH = os.environ.get("ALBEDO_TEST_CREDS") or os.path.join(
    os.environ.get("ALBEDO_HOME") or os.path.expanduser("~/.albedo"), "creds.json"
)
KEY = json.load(open(CREDS_PATH))["providers"]["deepseek"]["apiKey"]
MODEL = "deepseek-chat"
SKILL_BODY = "LIVE_SKILL_BODY_7391"

CELL_ONE = """
import inspect
print("NAMES", sorted(n for n in vars(type(commands)) if not n.startswith("_")))
print("SIG", inspect.signature(commands.model))
print("DOC", commands.model.__doc__.replace(chr(10), " | "))
print("SEL", await commands.model())
print("CAT", [(c["name"], c["method"], c.get("usage")) for c in await commands.catalog()])
act = await commands.probe("one  two")
print("ACT", repr(act["arguments"]), "LIVE_SKILL_BODY_7391" in act["instructions"])
print("INVOKED", (await commands.invoke("/probe", "raw text"))["arguments"])
try:
    await commands.model("unreachable-model")
    print("SWITCH-BUG")
except CommandsError as e:
    print("REFUSED", e)
"""
PROMPT_ONE = (
    "use the python tool to run exactly this one cell and nothing else, then "
    "end your turn with the single word done:\n" + CELL_ONE
)

PROMPT_TWO = (
    "use the python tool to run exactly this one cell and nothing else, then "
    "end your turn with the single word done:\n"
    "print('NOW', (await commands.model())['model'])"
)


def main():
    with tempfile.TemporaryDirectory(prefix="albedo-live-commands-") as directory:
        root = Path(directory)
        home, workspace, user_home = root / "home", root / "workspace", root / "user"
        for path in (home, workspace, user_home):
            path.mkdir(mode=0o700)
        skill = workspace / ".albedo" / "skills" / "probe" / "SKILL.md"
        skill.parent.mkdir(parents=True)
        skill.write_text(
            "---\nname: probe\ndescription: live probe skill\n---\n" + SKILL_BODY + "\n"
        )
        (home / "config.json").write_text(
            json.dumps(
                {
                    "active": "deepseek",
                    "providers": {
                        "deepseek": {
                            "baseUrl": "https://api.deepseek.com/v1",
                            "apiKey": KEY,
                            "model": MODEL,
                            "protocol": "chat_completions",
                        }
                    },
                }
            )
        )
        (home / "extensions.json").write_text(
            json.dumps({"models": {"refreshHours": 0}})
        )
        env = dict(
            os.environ,
            HOME=str(user_home),
            ALBEDO_HOME=str(home),
            ALBEDO_IDLE_SECONDS="600",
        )
        toolchain = ":".join(
            glob.glob("/nix/store/*gleam*/bin") + glob.glob("/nix/store/*erlang*/bin")
        )
        if toolchain:
            env["PATH"] = toolchain + ":" + env["PATH"]
        first = subprocess.run(
            [str(ROOT / "cli/bin/albedo"), "sessions"],
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            timeout=120,
        )
        assert first.returncode == 0, first.stdout + first.stderr
        connection = json.loads((home / "daemon.json").read_text())
        base = f"http://127.0.0.1:{connection['port']}"
        headers = {
            "Authorization": "Bearer " + connection["token"],
            "Content-Type": "application/json",
        }

        def api(path, body=None):
            request = urllib.request.Request(
                base + path,
                headers=headers,
                data=None if body is None else json.dumps(body).encode(),
            )
            return urllib.request.urlopen(request, timeout=60)

        def ready(session, timeout=180):
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                with api(f"/sessions/{session}/status") as response:
                    state = json.load(response)
                if not state["running"]:
                    return
                time.sleep(1)
            raise AssertionError(f"session never settled: {state}")

        def outputs(session):
            """The first stream page after reset is the full history snapshot."""
            with api(f"/sessions/{session}/stream?after_seq=-1") as response:
                response.fp.raw._sock.settimeout(60)
                while True:
                    line = response.readline()
                    if not line:
                        return []
                    if line.startswith(b"data: "):
                        return json.loads(line[6:])["events"]

        created = json.loads(
            subprocess.run(
                [str(ROOT / "cli/bin/albedo"), "new", str(workspace)],
                cwd=ROOT,
                env=env,
                text=True,
                capture_output=True,
                timeout=120,
                check=True,
            ).stdout
        )
        session = created["session"]
        print("session", session)

        with api(f"/sessions/{session}/commands") as response:
            catalog = json.load(response)
        by_name = {c["name"]: c for c in catalog}
        assert "/model" in by_name and "/context" in by_name and "/probe" in by_name, (
            by_name.keys()
        )
        assert by_name["/model"]["usage"] == "/model [model] [provider]", by_name[
            "/model"
        ]
        assert (
            by_name["/probe"]["method"] == "probe" and by_name["/probe"]["userTurn"]
        ), by_name["/probe"]
        print(
            "PASS catalog serves /model /context /probe with usage and mintable methods"
        )

        print("turn 1 submitted", flush=True)
        with api(f"/sessions/{session}/events", {"content": PROMPT_ONE}) as response:
            response.read()
        ready(session)
        print("turn 1 settled, reading stream", flush=True)
        tools = [e for e in outputs(session) if e.get("type") == "tool"]
        text = json.dumps([e.get("result", "") for e in tools])
        print("turn 1 tool outputs:", len(tools), flush=True)
        for marker in (
            "NAMES",
            "SIG",
            "DOC",
            "SEL",
            "CAT",
            "ACT",
            "INVOKED",
            "REFUSED",
        ):
            assert marker in text, (marker, text[-2000:])
        assert "['context', 'model', 'probe']" in text, text[-2000:]
        assert "INVOKED raw text" in text, text[-2000:]
        assert "(model=None, provider=None)" in text, text[-2000:]
        assert "Usage: /model [model] [provider]" in text, text[-2000:]
        assert f"'{MODEL}'" in text, text[-2000:]
        assert "'/model', 'model', '/model [model] [provider]'" in text, text[-2000:]
        assert "'one  two' True" in text, (
            "exact arguments + skill body round-trip",
            text[-2000:],
        )
        assert "SWITCH-BUG" not in text and "user action between turns" in text, text[
            -2000:
        ]
        print("PASS real model used the typed bindings: help/signature, read, catalog,")
        print("     skill with exact args, and the model-mode switch refusal")

        switch_to = MODEL
        try:
            with urllib.request.urlopen(
                urllib.request.Request(
                    "https://api.deepseek.com/models",
                    headers={"Authorization": "Bearer " + KEY},
                ),
                timeout=15,
            ) as response:
                listed = [m["id"] for m in json.load(response)["data"]]
            candidates = [m for m in listed if m != MODEL and "reasoner" not in m] or [
                m for m in listed if m != MODEL
            ]
            if candidates:
                switch_to = candidates[0]
        except Exception as probe_error:
            print("model list unavailable:", probe_error)
        if switch_to == MODEL:
            print("SKIP switch: no second deepseek model to switch to")
        else:
            with api(
                f"/sessions/{session}/commands",
                {"name": "/model", "args": {"model": switch_to}},
            ) as response:
                selection = json.load(response)
            assert selection["result"]["model"] == switch_to, selection
            assert selection["result"]["provider"] == "deepseek", selection
            with api(
                f"/sessions/{session}/events", {"content": PROMPT_TWO}
            ) as response:
                response.read()
            ready(session)
            tools = [e for e in outputs(session) if e.get("type") == "tool"]
            assert f"NOW {switch_to}" in json.dumps(tools), json.dumps(tools)[-2000:]
            print(f"PASS user switch landed: the next real request ran on {switch_to}")

        with contextlib.suppress(Exception):
            api("/shutdown", {}).close()
        print("PASS: live command surface e2e")


if __name__ == "__main__":
    main()
