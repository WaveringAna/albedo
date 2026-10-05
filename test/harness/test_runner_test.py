"""Empty test selections must fail before the gate can report success.

Application E2E cannot detect deleted test methods or runner discovery errors.
Use temporary suites and the real runner processes, without starting a daemon.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class TestRunnerTests(unittest.TestCase):
    def test_python_runner_rejects_empty_files_and_preserves_failure_exit(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "example_test.py"
            for source, successful, message in [
                ("import unittest\n", False, "no tests collected"),
                (
                    "import unittest\nclass Example(unittest.TestCase):\n"
                    "    def test_works(self): self.assertTrue(True)\n",
                    True,
                    "Ran 1 test",
                ),
                (
                    "import unittest\nclass Example(unittest.TestCase):\n"
                    "    def test_fails(self): self.fail('fixture failure')\n",
                    False,
                    "fixture failure",
                ),
            ]:
                with self.subTest(source=source):
                    path.write_text(source)
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(ROOT / "test/python_test_runner.py"),
                            str(path),
                        ],
                        capture_output=True,
                        text=True,
                        timeout=15,
                    )
                    self.assertEqual(result.returncode == 0, successful, result.stderr)
                    self.assertIn(message, result.stderr)

    def test_e2e_rejects_empty_file_among_valid_files_and_empty_aggregate(self):
        script = """
import sys, unittest
from pathlib import Path
sys.path.insert(0, str(Path('test/e2e').resolve()))
import run
root = Path(sys.argv[1])
valid = root / 'valid_test.py'
suite = run.suite_for(valid, 'Example.test_works')
assert suite.countTestCases() == 1
assert unittest.TextTestRunner().run(suite).wasSuccessful()
for collect in [
    lambda: unittest.TestSuite(run.suite_for(p) for p in sorted(root.glob('*_test.py'))),
    lambda: run.run_suite(unittest.TestSuite(), 1, 1),
]:
    try:
        collect()
    except ValueError as error:
        assert 'no ' in str(error) and 'tests collected' in str(error), str(error)
    else:
        raise AssertionError('empty selection passed')
"""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "empty_test.py").write_text("import unittest\n")
            (root / "valid_test.py").write_text(
                "import unittest\nclass Example(unittest.TestCase):\n"
                "    def test_works(self): pass\n"
            )
            result = subprocess.run(
                [sys.executable, "-c", script, directory],
                cwd=ROOT,
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_erlang_runner_requires_test_exports_but_ignores_support(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root / "test"
            tests.mkdir()
            sources = [
                ROOT / "test/albedo_test_runner.erl",
                ROOT / "test/albedo_test_home.erl",
            ]
            subprocess.run(
                ["erlc", "-Werror", "-o", directory, *map(str, sources)],
                check=True,
                timeout=30,
            )
            for source, successful, message in [
                (None, False, "no_test_modules"),
                (
                    "-module(example_test).\n-export([helper/0]).\nhelper() -> ok.\n",
                    False,
                    "no_tests_in_module",
                ),
                (
                    '-module(example_test).\n-include_lib("eunit/include/eunit.hrl").\n'
                    "ordinary_test() -> ?assert(true).\n"
                    "generated_test_() -> [?_assert(true)].\n",
                    True,
                    "",
                ),
            ]:
                with self.subTest(source=source):
                    if source is not None:
                        path = tests / "example_test.erl"
                        path.write_text(source)
                        subprocess.run(
                            ["erlc", "-Werror", "-o", directory, str(path)],
                            check=True,
                            timeout=30,
                        )
                    (tests / "fixture.erl").write_text(
                        "intentionally not a compiled test module\n"
                    )
                    # The actual Gleam entrypoint and fixtures must be excluded.
                    (tests / "albedo_test.gleam").write_text("pub fn main() { Nil }\n")
                    paths = [directory, str(ROOT / "build/dev/erlang/gleeunit/ebin")]
                    result = subprocess.run(
                        [
                            "erl",
                            "+S",
                            "2:2",
                            "-pa",
                            *paths,
                            "-noshell",
                            "-eval",
                            "albedo_test_home:isolate(), albedo_test_runner:main().",
                        ],
                        cwd=root,
                        env={**os.environ, "ALBEDO_TEST_TMP": str(root / "scratch")},
                        capture_output=True,
                        text=True,
                        timeout=30,
                    )
                    self.assertEqual(
                        result.returncode == 0,
                        successful,
                        result.stdout + result.stderr,
                    )
                    if message:
                        self.assertIn(message, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
