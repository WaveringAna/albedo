"""Measure one kernel's resident memory at boot and under scaled workloads.

Run in nix develop:
  python test/manual/kernel_memory_benchmark.py [--scale 1 10] [--output /tmp/kernel-memory.json]

Boots the kernel over stdio with the daemon's default module list, samples RSS
after `ready`, then runs each workload at every scale and reports the RSS delta
and the kernel's own accounting of what it retains (captures, finished results,
definitions, outbox). A workload whose delta grows with scale on a path that
should be bounded is the finding; the absolute numbers are the record.
"""

import argparse
import json
from pathlib import Path
import platform
import select
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
KERNEL = ROOT / "priv" / "python" / "albedo_kernel.py"  # --kernel-dir points elsewhere
sys.path.insert(0, str(ROOT / "test"))
import scratch  # noqa: E402

scratch.claim("kernel-memory")
MODULES = [
    "run",
    "work",
    "mail",
    "agents",
    "paperclips",
    "files",
    "memory",
    "commands",
    "remote",
    "browser",
    "view",
    "skills",
    "webhooks",
]
MAX_FRAME = 8 * 1024 * 1024
# Plugins that ask the host something at boot get the shape they expect.
HOST_ANSWERS = {
    "agents.self": {"id": "bench", "name": "bench", "depth": 0},
    "commands.list": [],
}

ACCOUNTING = """
import sys as _sys, gc as _gc, json as _json
_k = _sys.modules["__main__"]
_gc.collect()
_caps = list(_k.ARCHIVES.values())
_fin = list(_k.FINISHED.values())
_result = {
    "captures": len(_caps),
    "capture_bytes": sum(
        _sys.getsizeof(c.data)
        + _sys.getsizeof(getattr(c, "_tail", None) or b"")
        + _sys.getsizeof(getattr(c, "tail_data", b""))
        + _sys.getsizeof(getattr(c, "raw_data", b""))
        for c in _caps
    ),
    "finished": len(_fin),
    "finished_bytes": sum(len(str(d.get("output", ""))) + sum(map(len, d.get("images", []))) for d in _fin),
    "definitions": len(_k.DEFINITIONS),
    "definition_bytes": sum(map(len, _k.DEFINITIONS.values())),
    "outbox_entries": len(getattr(getattr(_k.LINK, "outbox", None), "entries", ())),
    "outbox_bytes": getattr(getattr(_k.LINK, "outbox", None), "size", 0),
    "modules": len(_sys.modules),
    "gc_objects": len(_gc.get_objects()),
}
print(_json.dumps(_result))
"""


def rss_kib(pid):
    out = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True
    )
    return int(out.stdout.strip() or 0)


class Kernel:
    def __init__(self, modules, cwd, kernel=KERNEL):
        self.process = subprocess.Popen(
            [sys.executable, "-u", str(kernel), json.dumps(modules)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            cwd=cwd,
            bufsize=0,
        )
        assert self.process.stdin is not None and self.process.stdout is not None
        self.stdin = self.process.stdin
        self.stdout = self.process.stdout
        self.buffered = []
        self.cells = 0

    def send(self, message):
        data = json.dumps(message).encode()
        self.stdin.write(struct.pack(">I", len(data)) + data)
        self.stdin.flush()

    def read_exactly(self, size):
        data = b""
        while len(data) < size:
            chunk = self.stdout.read(size - len(data))
            if not chunk:
                raise AssertionError(
                    f"kernel closed its control stream; last frames: {self.buffered[-3:]}"
                )
            data += chunk
        return data

    def recv(self, timeout):
        ready, _, _ = select.select([self.stdout], [], [], timeout)
        if not ready:
            return None
        size = struct.unpack(">I", self.read_exactly(4))[0]
        assert size <= MAX_FRAME
        return json.loads(self.read_exactly(size))

    def wait_for(self, predicate, timeout=120.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, frame in enumerate(self.buffered):
                if predicate(frame):
                    return self.buffered.pop(index)
            frame = self.recv(max(0.05, deadline - time.monotonic()))
            if frame is None:
                continue
            if frame.get("type") == "call":
                # Answer host calls the way an idle session would: accept and forget.
                value = HOST_ANSWERS.get(frame["method"])
                self.send(
                    {
                        "type": "reply",
                        "id": frame["id"],
                        "value": {"ok": True, "value": value},
                    }
                )
                continue
            self.buffered.append(frame)
        raise AssertionError(
            f"no matching frame; buffered: {[f.get('type') for f in self.buffered]}"
        )

    def execute(self, code, timeout_ms=600_000):
        self.cells += 1
        cell = f"bench-{self.cells}"
        self.send(
            {"type": "execute", "id": cell, "code": code, "timeout_ms": timeout_ms}
        )
        done = self.wait_for(lambda f: f.get("type") == "done" and f.get("id") == cell)
        if done["status"] != "ok":
            raise RuntimeError(f"cell {cell} failed: {done['output'][-2000:]}")
        return done

    def accounting(self):
        return json.loads(self.execute(ACCOUNTING)["output"])

    def close(self):
        self.send({"type": "shutdown"})
        self.process.wait(timeout=10)
        self.stdin.close()
        self.stdout.close()


def prints(kernel, scale, workspace):
    kernel.execute(
        f"for i in range({20_000 * scale}):\n"
        "    print('line', i, 'of output that is fairly ordinary')"
    )


def big_print(kernel, scale, workspace):
    kernel.execute(f"print('x' * {2 * 1024 * 1024 * scale})")


def jobs_output(kernel, scale, workspace):
    kernel.execute(
        f"for _ in range({scale}):\n"
        f"    batch = [run('head', '-c', '{256 * 1024}', '/dev/zero') for _ in range(8)]\n"
        "    for j in batch:\n        await j\n"
    )


def cells(kernel, scale, workspace):
    for i in range(50 * scale):
        kernel.execute(f"x{i} = {i}\nprint('cell', x{i})")


def defs(kernel, scale, workspace):
    for i in range(50 * scale):
        kernel.execute(f"def helper_{i}(a, b):\n    return a + b + {i}\n")


def audit_opens(kernel, scale, workspace):
    kernel.execute(
        "import os\n"
        f"paths = [os.path.join({workspace!r}, f'f{{i}}.txt') for i in range({2000 * scale})]\n"
        "for p in paths:\n    open(p, 'w').close()\n"
        "for p in paths:\n    open(p).close()\n"
        "for p in paths:\n    os.unlink(p)\n"
    )


# Each runs one workload in a fresh kernel; `scale` multiplies the size that grows.
WORKLOADS = {
    f.__name__: f for f in (prints, big_print, jobs_output, cells, defs, audit_opens)
}


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--scale", type=int, nargs="+", default=[1, 10])
    parser.add_argument("--output", type=Path, default=None)
    parser.add_argument("--only", nargs="*", default=None, help="workload names to run")
    parser.add_argument(
        "--kernel-dir",
        type=Path,
        default=KERNEL.parent,
        help="a priv/python to boot instead of this checkout's, for a baseline",
    )
    args = parser.parse_args()
    kernel_path = args.kernel_dir / "albedo_kernel.py"

    report = {
        "kernel": str(kernel_path),
        "platform": platform.platform(),
        "python": platform.python_version(),
        "modules": MODULES,
        "boot": {},
        "workloads": [],
    }
    workspace = tempfile.mkdtemp(prefix="albedo-kernel-bench-")
    kernel = Kernel(MODULES, workspace, kernel_path)
    started = time.perf_counter()
    kernel.wait_for(lambda f: f.get("type") == "ready")
    boot_seconds = time.perf_counter() - started
    time.sleep(0.2)
    boot_rss = rss_kib(kernel.process.pid)
    boot_accounting = kernel.accounting()
    report["boot"] = {
        "seconds": round(boot_seconds, 3),
        "rss_kib": boot_rss,
        **boot_accounting,
    }
    print(json.dumps({"boot": report["boot"]}), flush=True)

    for name, workload in WORKLOADS.items():
        if args.only is not None and name not in args.only:
            continue
        for scale in args.scale:
            fresh = Kernel(MODULES, workspace, kernel_path)
            fresh.wait_for(lambda f: f.get("type") == "ready")
            time.sleep(0.1)
            before = rss_kib(fresh.process.pid)
            started = time.perf_counter()
            workload(fresh, scale, workspace)
            seconds = time.perf_counter() - started
            after = rss_kib(fresh.process.pid)
            accounting = fresh.accounting()
            settled = rss_kib(fresh.process.pid)
            fresh.close()
            row = {
                "workload": name,
                "scale": scale,
                "seconds": round(seconds, 3),
                "rss_before_kib": before,
                "rss_after_kib": after,
                "rss_settled_kib": settled,
                "rss_delta_kib": after - before,
                **accounting,
            }
            report["workloads"].append(row)
            print(json.dumps(row), flush=True)
    kernel.close()
    if args.output is not None:
        args.output.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
