"""A remote login shell that is not POSIX (`nu`, `fish`, `tcsh`) must still run
the command albedo sends it. Real hosts with those shells are not in the test
environment, so every remote command would fail there as it did on
`regent@astaroth`: `-c` quoted POSIX redirections into `$SHELL`, and nu cannot
parse `exec 1>&3 2>&4`, so a login shell exits 1 with no output at all."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "priv" / "python"))
import albedo_ssh  # noqa: E402

SCRIPT = "cat; echo to-stdout; echo to-stderr >&2; exit 3"


def stand_in_shell(directory: Path, *, motd: str = "") -> str:
    """A shell that takes -l -c like nu and refuses POSIX redirection in it."""
    path = directory / "nu-stand-in"
    lines = ["#!/bin/sh", "shift", "shift"]
    if motd:
        lines.append(f'echo "{motd}"')
    lines.append('case "$1" in *">"*) echo "nu: refused: $1" >&2; exit 91 ;; esac')
    lines.append('exec /bin/sh -c "$1"')
    path.write_text("\n".join(lines) + "\n")
    path.chmod(0o755)
    return str(path)


class LoginShellTest(unittest.TestCase):
    def run_command(self, shell, command):
        return subprocess.run(
            ["/bin/sh", "-c", command],
            input="from-stdin\n",
            text=True,
            capture_output=True,
            env={**os.environ, "SHELL": shell},
            timeout=30,
        )

    def test_a_login_shell_that_is_not_posix_still_runs_the_command(self):
        with tempfile.TemporaryDirectory() as scratch:
            shell = stand_in_shell(Path(scratch), motd="Welcome to astaroth")
            done = self.run_command(shell, albedo_ssh.in_login_shell(SCRIPT))
        self.assertEqual(done.returncode, 3, done.stderr)
        self.assertEqual(done.stdout, "from-stdin\nto-stdout\n")
        self.assertEqual(done.stderr, "to-stderr\n")

    def test_a_posix_login_shell_still_passes_stdin_through(self):
        done = self.run_command("/bin/sh", albedo_ssh.in_login_shell(SCRIPT))
        self.assertEqual(done.returncode, 3)
        self.assertEqual(done.stdout, "from-stdin\nto-stdout\n")
        self.assertEqual(done.stderr, "to-stderr\n")

    def test_the_script_leaves_no_temporary_file(self):
        command = albedo_ssh.in_login_shell("true")
        before = set(Path("/tmp").glob("albedo-remote-*"))
        self.run_command("/bin/sh", command)
        self.assertEqual(set(Path("/tmp").glob("albedo-remote-*")), before)


if __name__ == "__main__":
    unittest.main()
