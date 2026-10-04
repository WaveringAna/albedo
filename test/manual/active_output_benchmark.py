"""Compare exported daemons through the real gated-provider E2E harness.

Run in nix develop:
  python test/manual/active_output_benchmark.py --baseline /tmp/baseline/albedo-daemon \
      --candidate /tmp/candidate/albedo-daemon --output /tmp/active-output-results.json

Twenty attachments follow one discarded warmup per case, alternating builds.
HTTP capture and complete reference hydration are timed separately. Throughput
is first-to-last responsive text delivery, not provider request/boot overhead.
RSS is sampled every 5 ms; Linux /proc is required for memory measurements.
"""

import argparse
import json
import os
from pathlib import Path
import platform
import statistics
import sys
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "e2e"))
import harness
from active_output_test import ActiveOutputProbe, PausedOutput, active_text


def summary(values):
    ordered = sorted(values)
    return {
        "samples": len(values),
        "median_ms": statistics.median(values),
        "p95_ms": ordered[int((len(ordered) - 1) * 0.95)],
        "raw_ms": values,
    }


class MemorySampler:
    def __init__(self, pid):
        self.pid, self.peak_kib = pid, 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.sample, daemon=True)

    def sample(self):
        while not self.stop.is_set():
            status = Path(f"/proc/{self.pid}/status").read_text()
            rss = next(
                int(line.split()[1])
                for line in status.splitlines()
                if line.startswith("VmRSS:")
            )
            self.peak_kib = max(self.peak_kib, rss)
            self.stop.wait(0.005)


def capture(app, paused):
    started = time.perf_counter()
    batch = app.stream_page(paused.session)
    captured = time.perf_counter()
    descriptors = batch["snapshot"].get("active_output", [])
    restored = {item["kind"]: active_text(app, item) for item in descriptors}
    complete = time.perf_counter()
    available = restored.get("text") == paused.prefix and (
        not paused.thinking or restored.get("thinking") == paused.thinking
    )
    return ((captured - started) * 1000, (complete - started) * 1000, available)


def delete_session(app, session):
    resource = f"/sessions/{session}?view=configuration"
    with app.api(resource) as response:
        revision = response.getheader("ETag")
        response.read()
    app.api(resource, method="DELETE", headers={"If-Match": revision}).close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", required=True)
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=20)
    parser.add_argument(
        "--trials",
        type=int,
        default=5,
        help="responsive throughput trials after warmup",
    )
    args = parser.parse_args()
    if args.samples < 1 or args.trials < 1:
        parser.error("samples and trials must be positive")
    test = unittest.TestCase()
    daemons, apps, samplers = {}, {}, {}
    reports = []
    try:
        for label in ("baseline", "candidate"):
            os.environ["ALBEDO_TEST_DAEMON"] = str(Path(getattr(args, label)).resolve())
            harness.snapshot_daemon()
            daemon = harness.Daemon("exclusive")
            daemons[label] = daemon
            with harness.on_daemon(daemon):
                apps[label] = harness.Albedo(
                    harness.Provider(lambda _: harness.Reply("text", value="unused")),
                    prepare=lambda app: app.daemon.env.update(ALBEDO_INSPECT="1"),
                )
                apps[label].__enter__()
            sampler = MemorySampler(daemon._pid)
            samplers[label] = sampler
            sampler.thread.start()

        probes = {label: ActiveOutputProbe(app) for label, app in apps.items()}
        other_sessions = {label: app.session() for label, app in apps.items()}
        cases = [
            ("small", ["x" * 256] * 64, ""),
            ("text-and-thinking", ["x" * 256] * 64, "r" * 16384),
            ("raw-boundary", ["x" * 256] * 256, ""),
            ("escaped-boundary", ['"\\\n' * 128] * 100, ""),
            ("unicode", ["α🙂" * 64] * 256, "β" * 8192),
            ("one-MiB", ["x" * 256] * 4096, ""),
        ]
        for name, chunks, thinking in cases:
            case = {
                "name": name,
                "chunks": len(chunks),
                "text_bytes": len("".join(chunks).encode()),
                "thinking_bytes": len(thinking.encode()),
                "builds": {},
            }
            paused = {}
            for label, app in apps.items():
                paused[label] = PausedOutput(test, app, app.provider, chunks, thinking)
                capture(app, paused[label])
                case["builds"][label] = {
                    "capture_ms": [],
                    "hydrated_ms": [],
                    "restored": [],
                    "unrelated_session_ms": [],
                    "responsive_delivery_ms": [],
                    "actor_after_prefix": probes[label].call(
                        "stats", paused[label].session
                    ),
                }
            for index in range(args.samples):
                for label in (
                    ("baseline", "candidate")
                    if index % 2 == 0
                    else ("candidate", "baseline")
                ):
                    capture_ms, hydrated_ms, restored = capture(
                        apps[label], paused[label]
                    )
                    measurements = case["builds"][label]
                    measurements["capture_ms"].append(capture_ms)
                    measurements["hydrated_ms"].append(hydrated_ms)
                    measurements["restored"].append(restored)
                    started = time.perf_counter()
                    with apps[label].api(
                        f"/sessions/{other_sessions[label]}?tail=0"
                    ) as response:
                        json.load(response)
                    measurements["unrelated_session_ms"].append(
                        (time.perf_counter() - started) * 1000
                    )
            for label, measurements in case["builds"].items():
                measurements["capture"] = summary(measurements.pop("capture_ms"))
                measurements["hydrated"] = summary(measurements.pop("hydrated_ms"))
                measurements["unrelated_session"] = summary(
                    measurements.pop("unrelated_session_ms")
                )
                measurements["all_attachments_restored"] = all(
                    measurements.pop("restored")
                )
                spill = apps[label].home / "active-output"
                measurements["spill_bytes_before_commit"] = sum(
                    path.stat().st_size for path in spill.glob("*.data")
                )
                paused[label].finish(test)
                measurements["spill_bytes_after_commit"] = sum(
                    path.stat().st_size for path in spill.glob("*.data")
                )
                delete_session(apps[label], paused[label].session)
                measurements["spill_bytes_after_delete"] = sum(
                    path.stat().st_size for path in spill.glob("*.data")
                )
            for trial in range(args.trials):
                for label in (
                    ("baseline", "candidate")
                    if trial % 2 == 0
                    else ("candidate", "baseline")
                ):
                    app = apps[label]
                    output = PausedOutput(test, app, app.provider, chunks, thinking)
                    assert (
                        output.prefix_at is not None
                        and output.first_text_at is not None
                    )
                    case["builds"][label]["responsive_delivery_ms"].append(
                        (output.prefix_at - output.first_text_at) * 1000
                    )
                    output.finish(test)
                    delete_session(app, output.session)
            for measurements in case["builds"].values():
                measurements["responsive_delivery"] = summary(
                    measurements.pop("responsive_delivery_ms")
                )
            reports.append(case)
            print(
                json.dumps(
                    {
                        "case": name,
                        "builds": {
                            label: {
                                "capture_median_ms": values["capture"]["median_ms"],
                                "hydrated_median_ms": values["hydrated"]["median_ms"],
                                "delivery_median_ms": values["responsive_delivery"][
                                    "median_ms"
                                ],
                                "restored": values["all_attachments_restored"],
                                "spill_after_delete": values[
                                    "spill_bytes_after_delete"
                                ],
                            }
                            for label, values in case["builds"].items()
                        },
                    }
                ),
                flush=True,
            )
        args.output.write_text(
            json.dumps(
                {
                    "launchers": {label: getattr(args, label) for label in apps},
                    "method": {
                        "platform": platform.platform(),
                        "python": platform.python_version(),
                        "vm_flags": harness.TEST_VM_FLAGS,
                        "attach_samples": args.samples,
                        "throughput_trials": args.trials,
                        "rss_sample_ms": 5,
                        "actor_memory": "after GC, outside timed HTTP and throughput trials",
                        "hydrated_latency": "HTTP snapshot plus all active reference pages; baseline has no prefix",
                    },
                    "rss_peak_kib": {
                        label: sampler.peak_kib for label, sampler in samplers.items()
                    },
                    "cases": reports,
                },
                indent=2,
            )
            + "\n"
        )
    finally:
        test.doCleanups()
        for sampler in samplers.values():
            sampler.stop.set()
            sampler.thread.join()
        for app in apps.values():
            app.provider.close()
            app.__exit__()
        harness.shutdown()


if __name__ == "__main__":
    main()
