"""How the nix shim rewrites a command line in a jj workspace without .git.
Each case costs a real nix evaluation end to end, and the mistakes are
quiet: a lock file written over the workspace's (`--inputs-from .` once
wrote nixpkgs' empty lock into it), a flake inserted into a command that takes
none, or a lock written into the main checkout the ref names."""

import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_nix  # noqa: E402


@unittest.skipUnless(shutil.which("nix"), "needs nix for its flag table")
class RewriteTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.workspace = Path(scratch.name).resolve() / "ws"
        (self.workspace / ".jj").mkdir(parents=True)
        (self.workspace / "flake.nix").write_text("{ outputs = _: {}; }\n")
        os.environ["ALBEDO_HOME"] = scratch.name
        nix = shutil.which("nix")
        assert nix is not None
        self.table = albedo_nix.flag_table(nix)
        patch = mock.patch.object(albedo_nix, "flake_ref", return_value="REF")
        patch.start()
        self.addCleanup(patch.stop)

    def read(self, line: str) -> albedo_nix.Command:
        return albedo_nix.read(line.split(), self.table)

    def rewrite(self, line: str) -> str | None:
        command = self.read(line)
        result = albedo_nix.rewritten(command, self.workspace)
        if result is None:
            return None
        lock = str(self.workspace / "flake.lock")
        return " ".join(result[0]).replace(lock, "LOCK")

    def test_the_workspace_lock_is_written_only_for_the_workspace_flake(self):
        cases = {
            "build": "build --output-lock-file LOCK REF",
            "-L build .#x": "-L build --output-lock-file LOCK REF#x",
            "run .#x ./arg": "run --output-lock-file LOCK REF#x ./arg",
            "flake update nixpkgs": "flake update --output-lock-file LOCK --flake REF nixpkgs",
            "profile install .#x": "profile install --output-lock-file LOCK REF#x",
            # another flake is locked too: the workspace's lock is left alone
            "build .#a nixpkgs#b": "build --no-write-lock-file REF#a nixpkgs#b",
            "shell --inputs-from . nixpkgs#hello -c hello": (
                "shell --no-write-lock-file --inputs-from REF nixpkgs#hello -c hello"
            ),
            "why-depends .#a nixpkgs#b": "why-depends --no-write-lock-file REF#a nixpkgs#b",
        }
        for line, expected in cases.items():
            with self.subTest(line):
                self.assertEqual(self.rewrite(line), expected)

    def test_commands_that_name_no_local_flake_are_left_alone(self):
        for line in [
            "build nixpkgs#hello",
            "eval --expr 1",
            "eval",
            "build -f . hello",
            "store gc",
            "path-info --all",
            "flake show github:owner/repo",
        ]:
            with self.subTest(line):
                self.assertIsNone(self.rewrite(line))

    def test_the_formatter_runs_from_the_commit_at_the_flake_root(self):
        command = self.read("fmt --impure src")
        result = albedo_nix.rewritten(command, self.workspace)
        assert result is not None
        words, environment = result
        self.assertEqual(
            words,
            [
                "run",
                "--output-lock-file",
                str(self.workspace / "flake.lock"),
                f"REF#formatter.{albedo_nix.system()}",
                "--impure",
                "--",
                "src",
            ],
        )
        self.assertEqual(environment, {"PRJ_ROOT": str(self.workspace)})

    def test_committing_a_lock_into_the_main_checkout_is_refused(self):
        with self.assertRaises(albedo_nix.NixError):
            self.rewrite("flake lock --commit-lock-file")

    def test_unknown_commands_and_flags_go_to_nix_to_refuse(self):
        for line in ["frobnicate .", "build --frobnicate"]:
            with self.subTest(line), self.assertRaises(albedo_nix.Unreadable):
                self.read(line)


if __name__ == "__main__":
    unittest.main()
