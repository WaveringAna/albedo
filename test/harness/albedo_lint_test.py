"""The albedo lint rules (tools/lint) fire where they should and stay quiet where
the docs allow the construct. A rule that silently matches nothing (a renamed
`gleam/string` alias, a pipe, a path the runner no longer recognises) leaves the
checkout "clean" while the invariant breaks, and no e2e run can see that.
"""

import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

CONFIG = """
[tools.glinter]
include = ["src/", "test/"]

[tools.glinter.rules]
albedo_clock = "error"
albedo_text_scalars = "error"
albedo_table_ownership = "error"
"""

CLEAN = "pub fn id(text: String) -> String {\n  text\n}\n"


def lint(files: dict[str, str]) -> list[tuple[str, str, int]]:
    """Run albedo-lint on a scratch project; returns (rule, file, line) per finding."""
    binary = shutil.which("albedo-lint")
    if binary is None:
        raise unittest.SkipTest("albedo-lint is not on PATH (run inside nix develop)")
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        (root / "gleam.toml").write_text(CONFIG)
        for path, source in files.items():
            target = root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
        done = subprocess.run(
            [binary, "--project", directory, "--format", "json"],
            capture_output=True,
            text=True,
            check=False,
        )
        start = done.stdout.index("{")
        results = json.loads(done.stdout[start:])["results"]
        return [
            (r["rule"], r["file"], r["line"])
            for r in results
            if r["rule"].startswith("albedo_")
        ]


def module(body: str, imports: str = "import gleam/string\n") -> str:
    return f"{imports}\n{body}\n"


class TextScalarsTests(unittest.TestCase):
    def test_every_way_to_call_a_grapheme_function_is_found(self):
        found = lint(
            {
                "src/albedo/daemon/a.gleam": module(
                    "pub fn a(t: String) -> Int {\n  string.length(t)\n}"
                ),
                "src/albedo/daemon/b.gleam": module(
                    "pub fn b(t: String) -> String {\n  t |> string.slice(0, 5)\n}"
                ),
                "src/albedo/daemon/c.gleam": module(
                    "pub fn c(t: List(String)) -> List(Int) {\n  list.map(t, string.length)\n}",
                    "import gleam/list\nimport gleam/string\n",
                ),
                "src/albedo/daemon/d.gleam": module(
                    "pub fn d(t: String) -> String {\n  s.drop_end(t, 1)\n}",
                    "import gleam/string as s\n",
                ),
            }
        )
        self.assertEqual(
            sorted(
                (file, line)
                for rule, file, line in found
                if rule == "albedo_text_scalars"
            ),
            [
                ("src/albedo/daemon/a.gleam", 4),
                ("src/albedo/daemon/b.gleam", 4),
                ("src/albedo/daemon/c.gleam", 5),
                ("src/albedo/daemon/d.gleam", 4),
            ],
        )

    def test_the_owner_tests_and_other_string_functions_are_not_flagged(self):
        found = lint(
            {
                "src/albedo/text_scalars.gleam": module(
                    "pub fn length(t: String) -> Int {\n  string.length(t)\n}"
                ),
                "test/harness/x_test.gleam": module(
                    "pub fn x(t: String) -> Int {\n  string.length(t)\n}"
                ),
                "src/albedo/daemon/e.gleam": module(
                    "pub fn e(t: String) -> String {\n  string.trim(t) <> string.uppercase(t)\n}"
                ),
            }
        )
        self.assertEqual(found, [])


class ClockTests(unittest.TestCase):
    def test_clock_externals_and_timestamps_are_flagged_outside_clock(self):
        found = lint(
            {
                "src/albedo/clock.gleam": '@external(erlang, "erlang", "system_time")\n'
                "fn system_time(unit: Int) -> Int\n",
                "src/albedo/daemon/f.gleam": '@external(erlang, "os", "system_time")\n'
                "fn now(unit: Int) -> Int\n",
                "src/albedo/daemon/g.gleam": "import gleam/time/timestamp\n\n" + CLEAN,
                "src/albedo/daemon/h.gleam": '@external(erlang, "erlang", "binary_to_list")\n'
                "fn chars(text: String) -> List(Int)\n",
            }
        )
        self.assertEqual(
            sorted(
                (file, line) for rule, file, line in found if rule == "albedo_clock"
            ),
            [("src/albedo/daemon/f.gleam", 2), ("src/albedo/daemon/g.gleam", 1)],
        )


class TableOwnershipTests(unittest.TestCase):
    OWNER = (
        "src/albedo/harness/extensions/python/ledger.gleam",
        'pub const schema = "CREATE TABLE IF NOT EXISTS cells (id TEXT);"\n'
        'pub const read = "SELECT id FROM cells"\n',
    )

    def test_other_modules_naming_an_extension_table_are_flagged(self):
        found = lint(
            {
                self.OWNER[0]: self.OWNER[1],
                "src/albedo/daemon/storage.gleam": 'pub const q = "SELECT id FROM cells"\n',
                "src/albedo/harness/extensions/mail/ledger.gleam": 'pub const q = "DELETE FROM\n  cells WHERE id = ?"\n',
            }
        )
        self.assertEqual(
            sorted(
                (file, line)
                for rule, file, line in found
                if rule == "albedo_table_ownership"
            ),
            [
                ("src/albedo/daemon/storage.gleam", 1),
                ("src/albedo/harness/extensions/mail/ledger.gleam", 1),
            ],
        )

    def test_the_owner_core_tables_and_longer_names_are_not_flagged(self):
        found = lint(
            {
                self.OWNER[0]: self.OWNER[1],
                "src/albedo/daemon/other.gleam": 'pub const q = "SELECT id FROM cells_archive JOIN sessions"\n',
                "test/harness/t_test.gleam": 'pub const q = "SELECT id FROM cells"\n',
            }
        )
        self.assertEqual(found, [])


if __name__ == "__main__":
    unittest.main()
