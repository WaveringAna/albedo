"""Opt-in macOS benchmark: live task with the actual CLI attached to a PTY.
Uses the active ~/.albedo provider in an isolated home; never prints credentials.
"""
import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import statistics
import struct
import subprocess
import termios
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]


def cpu_seconds(value):
    parts = value.split(":")
    return sum(float(part) * 60 ** position for position, part in enumerate(reversed(parts)))


def processes():
    text = subprocess.check_output(["ps", "-axo", "pid=,ppid=,rss=,time=,comm="], text=True)
    rows = {}
    for line in text.splitlines():
        fields = line.split(None, 4)
        if len(fields) == 5:
            pid, parent, rss, cpu, command = fields
            rows[int(pid)] = dict(parent=int(parent), rss_kib=int(rss), cpu=cpu_seconds(cpu), command=command)
    return rows


def summarize(samples):
    result = {}
    for phase in sorted({sample["phase"] for sample in samples}):
        selected = [sample for sample in samples if sample["phase"] == phase]
        elapsed = sum(sample["interval"] for sample in selected)
        groups = {}
        for group in ("daemon", "python", "cli", "tools", "total"):
            values = [sample["groups"][group] for sample in selected]
            groups[group] = {
                "mean_cpu_pct": round(sum(value["cpu_seconds"] for value in values) / elapsed * 100, 2),
                "peak_cpu_pct": round(max(value["cpu_seconds"] / sample["interval"] * 100 for value, sample in zip(values, selected)), 2),
                "mean_rss_mib": round(sum(value["rss_kib"] * sample["interval"] for value, sample in zip(values, selected)) / elapsed / 1024, 2),
                "peak_rss_mib": round(max(value["rss_kib"] for value in values) / 1024, 2),
            }
        result[phase] = {"seconds": round(elapsed, 2), "samples": len(selected), "groups": groups}
    return result


def run(output, prompt, timeout):
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    home = output / "home"
    home.mkdir(mode=0o700)
    workspace = output / "workspace"
    workspace.mkdir()
    saved = json.loads((Path.home() / ".albedo/config.json").read_text())
    name = saved.get("active", "default")
    provider = saved.get("providers", {"default": saved})[name]
    config = home / "config.json"
    fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump({"active": name, "providers": {name: provider}}, file)
    metadata = {"provider": name, "model": provider["model"], "protocol": provider["protocol"],
                "terminal": {"columns": 120, "rows": 40}, "sample_seconds": 1,
                "cpu_basis": "100% = one logical core; deltas of sampled ps CPU time",
                "memory_basis": "RSS; sums may count shared pages more than once; short-lived processes can be missed"}
    del saved, provider
    (output / "task.txt").write_text(prompt)
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    env = {**os.environ, "ALBEDO_HOME": str(home), "TERM": "xterm-256color"}
    connection = None
    cli = None
    master = None
    samples = []
    owners = {}
    previous = {}
    terminal_bytes = 0
    try:
        created = subprocess.run([str(ROOT / "cli/bin/albedo"), "new", str(workspace)],
                                 cwd=ROOT, env=env, text=True, capture_output=True, timeout=60, check=True)
        session = json.loads(created.stdout)["session"]
        connection = json.loads((home / "daemon.json").read_text())
        def api(path, body=None):
            req = urllib.request.Request(f"http://127.0.0.1:{connection['port']}" + path,
                headers={"Authorization": "Bearer " + connection["token"], "Content-Type": "application/json"},
                data=None if body is None else json.dumps(body).encode())
            with urllib.request.urlopen(req, timeout=15) as response:
                return json.load(response)
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
        cli = subprocess.Popen([str(ROOT / "cli/bin/albedo"), "resume", session],
            cwd=workspace, env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
        os.close(slave)
        os.set_blocking(master, False)
        owners[connection["pid"]] = "daemon"
        owners[cli.pid] = "cli"
        selector = selectors.DefaultSelector()
        selector.register(master, selectors.EVENT_READ)
        phase = "idle_before"
        started = last_sample = time.monotonic()
        phase_start = started
        next_sample = started + 1
        submitted = None
        with (output / "terminal.log").open("wb") as terminal, (output / "samples.jsonl").open("w") as trace:
            while True:
                for key, _ in selector.select(max(0, next_sample - time.monotonic())):
                    try:
                        chunk = os.read(key.fd, 65536)
                    except (BlockingIOError, OSError):
                        chunk = b""
                    if chunk:
                        terminal.write(chunk)
                        terminal_bytes += len(chunk)
                now = time.monotonic()
                if cli.poll() is not None:
                    raise RuntimeError("attached cli exited during benchmark; inspect terminal.log")
                if now < next_sample:
                    continue
                rows = processes()
                for pid, row in rows.items():
                    if pid in owners:
                        continue
                    lineage = []
                    ancestor = pid
                    while ancestor in rows and ancestor not in owners and ancestor not in lineage:
                        lineage.append(ancestor)
                        ancestor = rows[ancestor]["parent"]
                    if ancestor not in owners:
                        continue
                    owner = owners[ancestor]
                    for descendant in reversed(lineage):
                        if owner == "python" or owner == "tools":
                            owner = "tools"
                        elif owner == "daemon" and "python" in Path(rows[descendant]["command"]).name.lower():
                            owner = "python"
                        owners[descendant] = owner
                groups = {group: {"rss_kib": 0, "cpu_seconds": 0} for group in ("daemon", "python", "cli", "tools", "total")}
                active_pids = {}
                for pid, group in owners.items():
                    if pid not in rows:
                        continue
                    row = rows[pid]
                    cpu = max(0, row["cpu"] - previous.get(pid, row["cpu"] if not samples else 0))
                    previous[pid] = row["cpu"]
                    groups[group]["rss_kib"] += row["rss_kib"]
                    groups[group]["cpu_seconds"] += cpu
                    active_pids[str(pid)] = group
                for group in ("daemon", "python", "cli", "tools"):
                    for metric in ("rss_kib", "cpu_seconds"):
                        groups["total"][metric] += groups[group][metric]
                status = api(f"/sessions/{session}/status")
                sample = {"elapsed": now - started, "interval": now - last_sample, "phase": phase,
                          "groups": groups, "pids": active_pids, "status": status, "terminal_bytes": terminal_bytes}
                samples.append(sample)
                trace.write(json.dumps(sample) + "\n")
                trace.flush()
                if len(samples) % 15 == 0:
                    print(json.dumps({"elapsed": round(now-started), "phase": phase, "rss_mib": round(groups["total"]["rss_kib"]/1024, 1), "terminal_bytes": terminal_bytes}), flush=True)
                last_sample = now
                next_sample = now + 1
                if phase == "idle_before" and now - phase_start >= 8:
                    if terminal_bytes == 0:
                        raise RuntimeError("attached cli produced no terminal output")
                    api(f"/sessions/{session}/events", {"content": prompt})
                    phase = "active"
                    submitted = phase_start = time.monotonic()
                    print(json.dumps({"event": "submitted", "session": session}), flush=True)
                elif phase == "active" and not status["running"]:
                    phase = "idle_after"
                    phase_start = now
                elif phase == "active" and submitted and now-submitted > timeout:
                    api(f"/sessions/{session}/interrupt", {})
                    raise TimeoutError("live task exceeded benchmark deadline")
                elif phase == "idle_after" and now - phase_start >= 8:
                    break
        req = urllib.request.Request(f"http://127.0.0.1:{connection['port']}/sessions/{session}/stream",
                                     headers={"Authorization": "Bearer " + connection["token"]})
        with urllib.request.urlopen(req, timeout=15) as response:
            while line := response.readline():
                if line.startswith(b"data: "):
                    events = json.loads(line[6:])["events"]
                    break
            else:
                raise RuntimeError("no final session snapshot")
        (output / "events.json").write_text(json.dumps(events, indent=2))
        summary = {"metadata": metadata, "session": session, "terminal_bytes": terminal_bytes,
                   "tool_calls": sum(event.get("type") == "tool" for event in events),
                   "final_messages": [event["text"] for event in events if event.get("type") == "message"][-2:],
                   "phases": summarize(samples)}
        (output / "summary.json").write_text(json.dumps(summary, indent=2))
        print(json.dumps(summary, indent=2), flush=True)
    finally:
        if samples and not (output / "summary.json").exists():
            (output / "partial-summary.json").write_text(json.dumps(summarize(samples), indent=2))
        if cli and cli.poll() is None:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(cli.pid, signal.SIGTERM)
            try:
                cli.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(cli.pid, signal.SIGKILL)
                cli.wait()
        if master is not None:
            os.close(master)
        if connection:
            with contextlib.suppress(Exception):
                api("/shutdown", {})
        config.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("prompt", type=Path)
    parser.add_argument("--timeout", type=int, default=1200)
    args = parser.parse_args()
    run(args.output.resolve(), args.prompt.read_text(), args.timeout)
