"""The nix and cargo shims through the real kernel: in a jj workspace without
.git, `nix develop -c` runs a program in a dev shell built from the
workspace's commit (with its packages and shellHook) and cached, and nix reads
the flake from that commit instead of copying the directory; cargo goes
through mbx, with the environment mbx needs to share builds across checkouts."""

import json
import shutil
import subprocess
import unittest
from pathlib import Path

from harness import Albedo, Provider, exclusive, python, text

ROOT = Path(__file__).resolve().parents[2]


def script_for(test):
    def script(request):
        if request["messages"][-1].get("role") == "user":
            return python(test.code)
        return text("done")

    return script


def cell_results(app, session):
    return [
        json.loads(part["value"])
        for entry in app.history(session)["items"]
        if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
        for part in entry["content"]
        if part["kind"] == "json" and part["field"] == "result"
    ]


FAKE_MBX = """#!/bin/sh
echo "mbx $* sdk=${SDKROOT-unset} cc=${CC-unset} mode=$MBX_CARGO_SHIM_MODE flags=$HOST_CFLAGS"
"""


class CargoShimTests(unittest.TestCase):
    def setUp(self):
        self.provider = Provider(script_for(self))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def test_cargo_runs_through_mbx_without_what_keeps_builds_apart(self):
        bin = self.app.workspace / "bin"
        bin.mkdir()
        for name, script in (
            ("mbx", FAKE_MBX),
            ("cc", "#!/bin/sh\n"),
            ("gcc", "#!/bin/sh\n"),
        ):
            (bin / name).write_text(script)
            (bin / name).chmod(0o755)
        # the shell's compiler under another name, as clang is cc in a nix shell
        (bin / "clang").symlink_to("cc")
        session = self.app.session()
        self.code = (
            f"path = {str(bin)!r} + ':' + os.environ['PATH']\n"
            "for cc, extra in (('clang', {}), ('clang', {'ALBEDO_NIX_ENV': 'abc'}),\n"
            "                  ('gcc', {'ALBEDO_NIX_ENV': 'abc'})):\n"
            "    env = {'PATH': path, 'SDKROOT': '/nix/store/x-sdk', 'CC': cc, **extra}\n"
            "    job = run('cargo', 'build', env=env)\n"
            "    await job\n"
            "    print(job.tail().strip())\n"
        )
        self.app.prompt(session, "build").close()
        self.app.idle(session)
        lines = cell_results(self.app, session)[-1]["output"].splitlines()
        # outside a nix shell a chosen compiler stays
        self.assertEqual(lines[0], "mbx build sdk=unset cc=clang mode=1 flags=")
        # inside a nix shell the shell's own cc goes to mbx, and the wrapper is keyed
        self.assertEqual(
            lines[1], "mbx build sdk=unset cc=unset mode=1 flags= -DALBEDO_NIX_ENV_abc"
        )
        # a shell that picks another compiler keeps it
        self.assertEqual(
            lines[2], "mbx build sdk=unset cc=gcc mode=1 flags= -DALBEDO_NIX_ENV_abc"
        )


def nixpkgs_lock():
    """albedo's own locked nixpkgs: in the store wherever its dev shell is, so
    the test flake needs no network."""
    lock = json.loads((ROOT / "flake.lock").read_text())
    return lock["nodes"][lock["nodes"]["root"]["inputs"]["nixpkgs"]]


FLAKE = """{
  inputs.nixpkgs.url = "github:%(owner)s/%(repo)s/%(ref)s";
  outputs = { self, nixpkgs }: {
    devShells = nixpkgs.lib.genAttrs
      [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ]
      (system: let pkgs = nixpkgs.legacyPackages.${system}; in {
        default = pkgs.mkShell {
          packages = [ (pkgs.writeShellScriptBin "albedo-nix-probe" "echo probe:$ALBEDO_NIX_MARK") ];
          shellHook = "export ALBEDO_NIX_MARK=from-hook";
        };
      });
    marker = "read-from-the-commit";
  };
}
"""


@exclusive
@unittest.skipUnless(shutil.which("nix") and shutil.which("jj"), "needs nix and jj")
class NixShellTests(unittest.TestCase):
    def setUp(self):
        def prepare(app):
            # a first dev shell evaluates nixpkgs; let the cell finish in place
            app.env["ALBEDO_CELL_BACKGROUND_SECONDS"] = "900"

        self.provider = Provider(script_for(self))
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)

    def jj(self, *args, cwd):
        subprocess.run(
            ["jj", *args],
            cwd=cwd,
            env=self.app.env,
            check=True,
            capture_output=True,
            timeout=120,
        )

    def test_a_jj_workspace_is_read_from_its_commit_and_its_shell_is_cached(self):
        node = nixpkgs_lock()
        main = self.app.workspace / "main"
        main.mkdir()
        (main / "flake.nix").write_text(FLAKE % node["original"])
        lock = {
            "nodes": {"nixpkgs": node, "root": {"inputs": {"nixpkgs": "nixpkgs"}}},
            "root": "root",
            "version": 7,
        }
        (main / "flake.lock").write_text(json.dumps(lock))
        (main / ".gitignore").write_text("/build\n")
        self.jj("git", "init", cwd=main)
        self.jj("commit", "-m", "flake", cwd=main)
        workspace = self.app.workspace / "ws"
        self.jj("workspace", "add", "--name", "ws", str(workspace), cwd=main)
        self.assertFalse((workspace / ".git").exists())
        (workspace / "build").mkdir()
        (workspace / "build" / "output").write_bytes(b"\0" * 1_000_000)
        session = self.app.session(workspace)
        self.code = (
            "for name, argv in (('first', ['nix', 'develop', '-c', 'albedo-nix-probe']),\n"
            "                   ('again', ['nix', 'develop', '-c', 'albedo-nix-probe']),\n"
            "                   ('eval', ['nix', 'eval', '--raw', '.#marker'])):\n"
            "    job = run(*argv, timeout=900)\n"
            "    await job\n"
            "    print(name, job.exit_code, json.dumps(job.tail()))\n"
        )
        self.app.prompt(session, "use the dev shell").close()
        self.app.idle(session)
        result = cell_results(self.app, session)[-1]
        self.assertEqual(result["status"], "ok", result)
        runs = {
            name: (int(code), json.loads(output))
            for name, code, output in (
                line.split(" ", 2) for line in result["output"].splitlines()
            )
        }
        self.assertEqual(runs["first"][0], 0, runs["first"])
        self.assertIn("albedo: building the dev shell", runs["first"][1])
        self.assertTrue(runs["first"][1].endswith("probe:from-hook\n"))
        # the cached shell runs the program and says nothing else
        self.assertEqual(runs["again"], (0, "probe:from-hook\n"))
        code, output = runs["eval"]
        self.assertEqual(code, 0, output)
        self.assertIn(f"git+file://{main.resolve()}?rev=", output)
        self.assertTrue(output.endswith("read-from-the-commit"))
        # nothing nix locked went into the main checkout
        self.assertEqual(json.loads((main / "flake.lock").read_text()), lock)


if __name__ == "__main__":
    unittest.main()
