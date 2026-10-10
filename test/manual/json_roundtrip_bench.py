"""Compare the daemon's CPU and memory across builds on one scripted load.

The load is `--sessions` sessions run at once, each a model turn that makes
`--calls` python tool calls (every cell asks the kernel for the commands
catalog, a host-route call) and then streams a long final answer. The numbers
come from the daemon's own VM over inspection, so build the daemon you want to
measure and point at it:

    ALBEDO_TEST_DAEMON=$(test/snapshot-daemon.sh /tmp/bench/old) \
        python3 test/manual/json_roundtrip_bench.py

Or compare builds in one run, interleaved ABBA so a busy machine slows both
alike (give each build a label):

    python3 test/manual/json_roundtrip_bench.py \\
        --daemon old=/tmp/bench/old/albedo-daemon --daemon new=/tmp/bench/new/albedo-daemon

reductions and gc_words barely move with contention; cpu_ms and wall_s do, so
read those only on a quiet machine.
cpu_ms is the VM's CPU time, reductions its work, gc_words the heap the
collector reclaimed (garbage made), peak_mb the daemon's highest resident set
sampled every 50 ms.
"""

import argparse
import os
import re
import statistics
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "e2e"))

import harness  # noqa: E402
from harness import Albedo, Provider, python, text  # noqa: E402
from inspect_support import Inspection  # noqa: E402

CALL = "len(await commands.catalog())"
ANSWER = "a streamed word " * 200


def cell(kilobytes):
    """The cell's source: the host call, after `kilobytes` KiB of padding that
    the kernel's command carries (the daemon once decoded all of it per cell)."""
    pad = f'PAD = "{"x" * 1024 * kilobytes}"\n' if kilobytes else ""
    return pad + CALL


def script(calls, code):
    def reply(request):
        used = sum(
            1 for message in request["messages"] if message.get("role") == "tool"
        )
        return python(code) if used < calls else text(ANSWER)

    return reply


def numbers(output):
    return [int(value) for value in re.findall(r"\d+", output)]


class Meter:
    def __init__(self, inspection, pid):
        self.inspection = inspection
        self.pid = pid

    def read(self):
        return numbers(
            self.inspection.evaluate(
                "Read = fun() -> {Cpu, _} = erlang:statistics(runtime), "
                "{Red, _} = erlang:statistics(reductions), "
                "{_, Words, _} = erlang:statistics(garbage_collection), "
                "[Cpu, Red, Words] end, "
                'io:format("~w", [Call(erlang, apply, [Read, []])])'
            )
        )

    def rss_mb(self):
        out = subprocess.run(
            ["ps", "-o", "rss=", "-p", str(self.pid)], capture_output=True, text=True
        ).stdout
        return int(out) / 1024 if out.strip() else 0.0


def load(app, sessions, meter):
    """Run every session at once: the wall time and the highest RSS seen."""

    def run(session):
        app.prompt(session, "go").close()
        app.idle(session, timeout=180)

    peak = [meter.rss_mb()]
    done = threading.Event()

    def watch():
        while not done.wait(0.05):
            peak[0] = max(peak[0], meter.rss_mb())

    threads = [threading.Thread(target=run, args=(s,)) for s in sessions]
    watcher = threading.Thread(target=watch)
    started = time.monotonic()
    watcher.start()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    wall = time.monotonic() - started
    done.set()
    watcher.join()
    return wall, peak[0]


def measure(launcher, args):
    """Boot one daemon from `launcher` and run the load: one row per run."""
    harness._executable = launcher
    daemon = harness.Daemon("bench")
    daemon.env["ALBEDO_INSPECT"] = "1"
    provider = Provider(script(args.calls, cell(args.code_kb)), chunk_size=20)
    rows = []
    with harness.on_daemon(daemon):
        app = Albedo(provider)
        app.__enter__()
        try:
            meter = Meter(Inspection(app), daemon._pid)
            for index in range(args.repeat + 1):
                sessions = [app.session() for _ in range(args.sessions)]
                before = meter.read()
                wall, peak = load(app, sessions, meter)
                after = meter.read()
                if index:  # the first run warms the daemon
                    rows.append(
                        {
                            "wall_s": wall,
                            "cpu_ms": after[0] - before[0],
                            "reductions": after[1] - before[1],
                            "gc_words": after[2] - before[2],
                            "peak_mb": peak,
                        }
                    )
        finally:
            app.__exit__(None, None, None)
            provider.close()
            daemon.discard()
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--sessions", type=int, default=8)
    parser.add_argument("--calls", type=int, default=25)
    parser.add_argument("--repeat", type=int, default=4, help="runs per boot")
    parser.add_argument("--code-kb", type=int, default=0, help="padding in each cell")
    parser.add_argument(
        "--daemon",
        action="append",
        metavar="LABEL=LAUNCHER",
        help="a build to measure; give two or more to compare them",
    )
    parser.add_argument(
        "--rounds", type=int, default=2, help="boots of each build, ABBA order"
    )
    args = parser.parse_args()
    builds = [tuple(item.split("=", 1)) for item in args.daemon or []] or [
        ("daemon", os.environ["ALBEDO_TEST_DAEMON"])
    ]
    labels = [label for label, _ in builds]
    order = []
    for round_ in range(args.rounds):
        order += labels if round_ % 2 == 0 else labels[::-1]
    rows = {label: [] for label in labels}
    launchers = dict(builds)
    for label in order:
        taken = measure(launchers[label], args)
        rows[label] += taken
        print(
            f"{label:>10} boot: " + format_row(statistics_of(taken, statistics.median))
        )
    print()
    for label, taken in rows.items():
        print(
            f"{label:>10} median: "
            + format_row(statistics_of(taken, statistics.median))
        )
        print(f"{label:>10} min..max: " + spread(taken))
    if len(builds) == 2:
        (first, one), (second, two) = rows.items()
        print()
        for key in ("reductions", "gc_words", "cpu_ms", "peak_mb", "wall_s"):
            a = statistics.median(r[key] for r in one)
            b = statistics.median(r[key] for r in two)
            print(f"{key:>10}: {second} vs {first} {100 * (b - a) / a:+.1f}%")


def statistics_of(rows, fold):
    return {key: fold(row[key] for row in rows) for key in rows[0]}


def spread(rows):
    return "  ".join(
        f"{key} {min(r[key] for r in rows):.4g}..{max(r[key] for r in rows):.4g}"
        for key in ("reductions", "gc_words", "cpu_ms", "peak_mb")
    )


def format_row(row):
    return (
        f"wall {row['wall_s']:.2f}s  cpu {row['cpu_ms']:.0f}ms  "
        f"reductions {row['reductions'] / 1e6:.1f}M  gc_words {row['gc_words'] / 1e6:.1f}M  "
        f"peak {row['peak_mb']:.1f}MB"
    )


if __name__ == "__main__":
    main()
