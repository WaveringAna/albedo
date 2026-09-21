"""Opt-in deterministic CLI memory benchmark: real PTY and HTTP/SSE, no provider."""
import argparse
import contextlib
import fcntl
import http.server
import json
import os
from pathlib import Path
import pty
import selectors
import signal
import struct
import subprocess
import termios
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def run(output, samples=1200, interval=0.02, production=False):
    output.mkdir(parents=True, exist_ok=False)
    home = output / "home"
    home.mkdir()
    ready = threading.Event()
    ended = threading.Event()
    session = dict(id="memory", title="memory replay", workspace=str(output), model="fixture", protocol="responses", provider="fixture")

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_GET(self):
            if "/stream" in self.path:
                self.send_response(200)
                self.send_header("content-type", "text/event-stream")
                self.end_headers()
                def page(events, cursor):
                    self.wfile.write(("data: " + json.dumps(dict(cursor=cursor, events=events)) + "\n\n").encode())
                    self.wfile.flush()
                try:
                    page([dict(type="reset"), dict(type="user", text="profile a streaming coding session", source="chat", triggeredAt="fixture")], 0)
                    ready.set()
                    for i in range(samples):
                        # Changing full viewport; enough rows to require scrolling.
                        page([dict(type="thinking", text=f"row {i}: inspect allocation, retain history, preserve scrolling. " + "value " * 12 + "\n")], i+1)
                        time.sleep(interval)
                    page([dict(type="usage", completionTokens=samples)], samples+1)
                    ended.set()
                    while not stop.wait(0.5): self.wfile.write(b": keepalive\n\n"); self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError): pass
                return
            value = {"version": 2} if self.path == "/health" else [session] if self.path == "/sessions" else dict(running=not ended.is_set(), idle=ended.is_set(), phase="reasoning")
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(value).encode())

    stop = threading.Event()
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    (home / "daemon.json").write_text(json.dumps(dict(port=server.server_port, token="fixture", pid=os.getpid(), version=2)))
    (home / "config.json").write_text(json.dumps(dict(active="fixture", providers=dict(fixture=dict(baseUrl="http://127.0.0.1", apiKey="fixture", model="fixture", protocol="responses")))))
    preload = output / "sample.mjs"
    preload.write_text("""import { appendFileSync } from 'node:fs';
import { writeHeapSnapshot } from 'node:v8';
const sample = tag => appendFileSync(process.env.MEMORY_REPORT, JSON.stringify({time:Date.now(), tag, ...process.memoryUsage(), cpu:process.cpuUsage()})+'\\n');
setInterval(()=>sample('sample'), 500).unref();
process.on('SIGUSR2',()=>{ global.gc(); sample('collected'); if(process.env.MEMORY_SNAPSHOT) writeHeapSnapshot(process.env.MEMORY_SNAPSHOT); });
""")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 120, 0, 0))
    env = {**os.environ, "ALBEDO_HOME": str(home), "TERM": "xterm-256color", "MEMORY_REPORT": str(output / "samples.jsonl")}
    if production: env["NODE_ENV"] = "production"
    child = subprocess.Popen(["node", "--expose-gc", "--import", str(preload), os.environ.get("MEMORY_LAUNCHER", str(ROOT / "cli/bin/albedo.mjs")), "resume", "memory"], env=env, stdin=slave, stdout=slave, stderr=slave, start_new_session=True)
    os.close(slave)
    os.set_blocking(master, False)
    selector = selectors.DefaultSelector()
    selector.register(master, selectors.EVENT_READ)
    started = time.monotonic()
    finished = None
    collected = False
    try:
        with (output / "terminal.log").open("wb") as log:
            while child.poll() is None:
                for key, _ in selector.select(0.1):
                    with contextlib.suppress(BlockingIOError, OSError): log.write(os.read(key.fd, 65536))
                now = time.monotonic()
                if ended.is_set() and finished is None: finished = now
                if finished is not None and now-finished > 3 and not collected:
                    child.send_signal(signal.SIGUSR2)
                    collected = True
                if finished is not None and now-finished > 5: break
                if now-started > samples*interval+30: raise TimeoutError("fixture timed out")
        if not collected: raise RuntimeError("CLI did not complete; inspect terminal.log")
        rows = [json.loads(line) for line in (output / "samples.jsonl").read_text().splitlines()]
        collected = next(row for row in rows if row["tag"] == "collected")
        active = [row for row in rows if row["time"] < collected["time"]]
        result = {"samples": samples, "seconds": round(now-started, 2),
                  "node_env": env.get("NODE_ENV", "launcher default"),
                  "peak_rss_mib": round(max(row["rss"] for row in active)/2**20, 2),
                  "peak_heap_mib": round(max(row["heapUsed"] for row in active)/2**20, 2),
                  "collected": collected}
        (output / "summary.json").write_text(json.dumps(result, indent=2))
        print(json.dumps(result), flush=True)
    finally:
        stop.set()
        if child.poll() is None:
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait()
        os.close(master)
        selector.close()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--samples", type=int, default=1200)
    parser.add_argument("--interval", type=float, default=0.02)
    parser.add_argument("--production", action="store_true")
    args = parser.parse_args()
    run(args.output.resolve(), args.samples, args.interval, args.production)
