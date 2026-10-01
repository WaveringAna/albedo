"""Run all E2E unittest suites, one file, or one test by dotted identifier.

Tests share one concurrent daemon; each ``@exclusive`` test gets a daemon of its
own, discarded when it ends, and a few of them run at a time beside the shared
ones. Both queues start with the tests that took longest last time, so the
slowest never start last.
"""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import resource
import sys
import time
import unittest

import harness
import scratch

SUITE_DIR = Path(__file__).parent
sys.path.insert(0, str(SUITE_DIR))
DURATIONS = scratch.ROOT / "e2e-durations.json"


def suite_for(path, test_name=None):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    loader = unittest.defaultTestLoader
    if test_name:
        return loader.loadTestsFromName(test_name, module)
    return loader.loadTestsFromModule(module)


def cases(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from cases(item)
        else:
            yield item


def marked(test, mark):
    method = getattr(test, test._testMethodName)
    return getattr(method, mark, False) or getattr(type(test), mark, False)


def execute(test, daemon):
    log = daemon.home / "daemon.log"
    offset = log.stat().st_size if log.exists() else 0
    stream = io.StringIO()
    started = time.monotonic()
    with harness.on_daemon(daemon):
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(test)
    duration = time.monotonic() - started
    if not result.wasSuccessful() and log.exists():
        # The daemon's side of a failure; the shared daemon's log interleaves
        # the tests that ran alongside this one.
        with log.open("rb") as daemon_log:
            daemon_log.seek(offset)
            setattr(
                result, "daemon_log", daemon_log.read()[-8000:].decode(errors="replace")
            )
    return test, result, duration


def execute_alone(test):
    daemon = harness.Daemon("exclusive")
    try:
        return execute(test, daemon)
    finally:
        daemon.discard()


def run_suite(suite, jobs, exclusive_jobs):
    try:
        durations = json.loads(DURATIONS.read_text())
    except OSError, ValueError:
        durations = {}
    selected = sorted(cases(suite), key=lambda test: -durations.get(test.id(), 0))
    exclusive = [test for test in selected if marked(test, "_e2e_exclusive")]
    shared = [test for test in selected if test not in exclusive]
    daemon = harness.Daemon("shared", concurrent=True) if shared else None
    if daemon:
        daemon.boot()
        daemon.install_shared_features()
    with (
        ThreadPoolExecutor(max_workers=exclusive_jobs) as exclusive_pool,
        ThreadPoolExecutor(max_workers=jobs) as shared_pool,
    ):
        alone = [exclusive_pool.submit(execute_alone, test) for test in exclusive]
        together = [shared_pool.submit(execute, test, daemon) for test in shared]
        outcomes = [future.result() for future in together + alone]
    report(outcomes)
    durations.update({test.id(): duration for test, _, duration in outcomes})
    DURATIONS.write_text(json.dumps(durations, indent=1, sort_keys=True))
    return all(result.wasSuccessful() for _, result, _ in outcomes)


def report(outcomes):
    for test, result, duration in outcomes:
        status = "ok" if result.wasSuccessful() else "FAILED"
        print(f"{status:6} {test.id()} ({duration:.1f}s)", file=sys.stderr)
    for test, result, _duration in outcomes:
        for _case, traceback in result.failures + result.errors:
            print(f"\n{test.id()}:\n{traceback}", file=sys.stderr)
        if getattr(result, "daemon_log", ""):
            print(
                f"daemon log during {test.id()}:\n{result.daemon_log}", file=sys.stderr
            )
    print("slowest tests:", file=sys.stderr)
    for test, _result, duration in sorted(outcomes, key=lambda value: -value[2])[:10]:
        print(f"  {duration:.1f}s {test.id()}", file=sys.stderr)
    failing = sum(not result.wasSuccessful() for _, result, _ in outcomes)
    print(f"Ran {len(outcomes)} tests; {failing} failing", file=sys.stderr)


def main():
    # Concurrent tests hold hundreds of connections between them, past the 256
    # open files a macOS shell starts with. Like Go, lift the soft limit, to at
    # most macOS's OPEN_MAX. Daemons boot on it unless a test pins their own.
    _, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    resource.setrlimit(resource.RLIMIT_NOFILE, (min(hard, 10240), hard))
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "target", nargs="?", help="file.py, file:TestCase.test_method, or area"
    )
    parser.add_argument(
        "-j", "--jobs", type=int, default=8, help="concurrent tests on the shared lane"
    )
    parser.add_argument(
        "-x",
        "--exclusive-jobs",
        type=int,
        default=12,
        help="concurrent exclusive tests, each on a daemon of its own",
    )
    args = parser.parse_args()
    if args.target:
        path = SUITE_DIR / args.target
        if path.is_file():
            suite = suite_for(path)
        else:
            file_part, _, test_name = args.target.partition(":")
            path = SUITE_DIR / (
                file_part if file_part.endswith(".py") else file_part + "_test.py"
            )
            suite = suite_for(path, test_name or None)
    else:
        suite = unittest.TestSuite(
            suite_for(path) for path in sorted(SUITE_DIR.glob("*_test.py"))
        )
    # Concurrent E2E runs compete for the daemons and kernels on this laptop.
    with open(scratch.ROOT / "e2e.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        started = time.monotonic()
        try:
            harness.snapshot_daemon()
            successful = run_suite(
                suite, max(1, args.jobs), max(1, args.exclusive_jobs)
            )
        finally:
            harness.shutdown()
            print(
                f"daemon boots: {harness.daemon_boots}; restart time: {harness.restart_seconds:.1f}s; wall time: {time.monotonic() - started:.1f}s",
                flush=True,
            )
    return 0 if successful else 1


if __name__ == "__main__":
    sys.exit(main())
