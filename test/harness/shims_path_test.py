"""Where the job PATH finds nix when the daemon started with a thin one: a GUI
or launchd start never ran the user's profile, so nix was missing from every
job and its shim was never put in front of it."""

from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_shims  # noqa: E402


class FallbackPathTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.addCleanup(os.environ.pop, "ALBEDO_HOME", None)
        os.environ["ALBEDO_HOME"] = str(self.root / "home")
        self.thin = self.root / "thin"
        self.thin.mkdir()
        self.profile = self.root / "profile"
        self.profile.mkdir()
        fallbacks = mock.patch.object(
            albedo_shims,
            "FALLBACKS",
            {"nix": (str(self.root / "missing"), str(self.profile))},
        )
        fallbacks.start()
        self.addCleanup(fallbacks.stop)

    def program(self, directory: Path, name: str = "nix") -> None:
        (directory / name).write_text("#!/bin/sh\n")
        (directory / name).chmod(0o755)

    def entries(self, environment: dict[str, str] | None) -> list[str]:
        assert environment is not None
        return environment["PATH"].split(os.pathsep)

    def test_a_missing_nix_is_found_in_the_first_directory_that_holds_it(self):
        self.program(self.profile)
        environment = albedo_shims.prepend({"PATH": str(self.thin)})
        entries = self.entries(environment)
        self.assertEqual(entries[1:], [str(self.thin), str(self.profile)])
        self.assertEqual(Path(entries[0]).parent.name, "shims")

    def test_the_fallback_never_shadows_a_nix_the_user_put_on_path(self):
        self.program(self.profile)
        users = self.root / "users"
        users.mkdir()
        self.program(users)
        entries = self.entries(albedo_shims.prepend({"PATH": str(users)}))
        self.assertEqual(entries[1:], [str(users)])

    def test_nothing_is_added_where_no_directory_holds_nix(self):
        self.assertEqual(
            albedo_shims.prepend({"PATH": str(self.thin)}), {"PATH": str(self.thin)}
        )

    def test_a_directory_without_an_executable_nix_is_not_added(self):
        (self.profile / "nix").write_text("not executable")
        self.assertEqual(
            albedo_shims.prepend({"PATH": str(self.thin)}), {"PATH": str(self.thin)}
        )

    def test_only_the_directory_that_holds_nix_joins_path(self):
        other = self.root / "other"
        other.mkdir()
        self.program(other, "unrelated")
        self.program(self.profile)
        with mock.patch.object(
            albedo_shims, "FALLBACKS", {"nix": (str(other), str(self.profile))}
        ):
            entries = self.entries(albedo_shims.prepend({"PATH": str(self.thin)}))
        self.assertNotIn(str(other), entries)
        self.assertIn(str(self.profile), entries)


if __name__ == "__main__":
    unittest.main()
