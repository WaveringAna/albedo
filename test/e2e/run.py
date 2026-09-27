"""Run all E2E unittest suites, one file, or one test by dotted identifier."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import io
import fcntl
import importlib.util
from pathlib import Path
import sys
import tempfile
import time
import unittest

import harness

SUITE_DIR = Path(__file__).parent
sys.path.insert(0, str(SUITE_DIR))


def suite_for(path, test_name=None):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    loader = unittest.defaultTestLoader
    if test_name:
        return loader.loadTestsFromName(test_name, module)
    return loader.loadTestsFromModule(module)


def migration_suite():
    return suite_for(SUITE_DIR / "integration_test.py",
                     "IntegrationTest.test_unconfigured_startup_and_legacy_provider_migration")


def without_migration(suite):
    return unittest.TestSuite(test for group in suite for test in group
                              if test._testMethodName !=
                              "test_unconfigured_startup_and_legacy_provider_migration")


def cases(suite):
    for item in suite:
        if isinstance(item, unittest.TestSuite):
            yield from cases(item)
        else:
            yield item


def execute(test, concurrent=False):
    harness._parallel.enabled = concurrent
    stream = io.StringIO()
    started = time.monotonic()
    try:
        result = unittest.TextTestRunner(stream=stream, verbosity=2).run(test)
        return test, result, time.monotonic() - started, stream.getvalue()
    finally:
        harness._parallel.enabled = False


def run_suite(suite, workers):
    selected = list(cases(suite))
    first = [test for test in selected if "test_unconfigured_startup_and_legacy_provider_migration" in test.id()]
    parallel = [test for test in selected if test not in first and
                not getattr(getattr(test, test._testMethodName), "_e2e_exclusive", False) and
                not getattr(type(test), "_e2e_exclusive", False)]
    exclusive = [test for test in selected if test not in first and test not in parallel]
    outcomes = [execute(test) for test in first]
    if parallel:
        harness.enable_parallel_features()
    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = [pool.submit(execute, test, True) for test in parallel]
        outcomes.extend(future.result() for future in as_completed(futures))
    outcomes.extend(execute(test) for test in exclusive)
    for test, result, duration, _output in outcomes:
        status = "ok" if result.wasSuccessful() else "FAILED"
        print(f"{status:6} {test.id()} ({duration:.1f}s)", file=sys.stderr)
    for test, result, _duration, _output in outcomes:
        for _case, traceback in result.failures + result.errors:
            print(f"\n{test.id()}:\n{traceback}", file=sys.stderr)
    print("slowest tests:", file=sys.stderr)
    for test, _result, duration, _output in sorted(outcomes, key=lambda value: -value[2])[:10]:
        print(f"  {duration:.1f}s {test.id()}", file=sys.stderr)
    print(f"Ran {len(outcomes)} tests; {sum(not result.wasSuccessful() for _, result, _, _ in outcomes)} failing", file=sys.stderr)
    return all(result.wasSuccessful() for _, result, _, _ in outcomes)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target", nargs="?", help="file.py or TestCase.test_method")
    parser.add_argument("-j", "--jobs", type=int, default=8, help="concurrent non-exclusive tests")
    args = parser.parse_args()
    if args.target:
        path = SUITE_DIR / args.target
        if path.is_file():
            suite = suite_for(path)
            if path.name == "integration_test.py":
                suite = unittest.TestSuite([migration_suite(), without_migration(suite)])
        else:
            file_part, _, test_name = args.target.partition(":")
            path = SUITE_DIR / (file_part if file_part.endswith(".py") else file_part + "_test.py")
            suite = suite_for(path, test_name)
    else:
        paths = sorted(SUITE_DIR.glob("*_test.py"))
        suites = [migration_suite()]
        for path in paths:
            tests = suite_for(path)
            if path.name == "integration_test.py":
                tests = without_migration(tests)
            suites.append(tests)
        suite = unittest.TestSuite(suites)
    # Concurrent E2E runs compete for the daemon and kernels on this laptop.
    with open(Path(tempfile.gettempdir()) / "albedo-e2e.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        started = time.monotonic()
        try:
            successful = run_suite(suite, max(1, args.jobs))
        finally:
            harness.shutdown()
            print(f"daemon boots: {harness.daemon_boots}; restart time: {harness.restart_seconds:.1f}s; wall time: {time.monotonic() - started:.1f}s", flush=True)
    return 0 if successful else 1


if __name__ == "__main__":
    sys.exit(main())
