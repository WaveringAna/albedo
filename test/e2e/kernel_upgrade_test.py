"""A kernel on an older python bundle is swapped for a current one, namespace included.

After a daemon restart onto edited python code, the reattached kernel runs the
old code. At the session's next idle moment with no live jobs, it is replaced
by a kernel on the new bundle, its variables carried through a snapshot and a
restore; a live job holds the old kernel until it ends.
"""

import json
from pathlib import Path
import shutil
import tempfile
import time
import unittest

import harness
from harness import Albedo, Provider, exclusive, python, text

MARKER = '\nMARKER = "new bundle"\n'


def editable_daemon(root):
    """A copy of the test daemon whose python bundle is ours to edit: every
    package links back to the snapshot except albedo's priv/python."""
    assert harness._executable is not None, "the runner snapshots the daemon first"
    source = Path(harness._executable).parent
    out = Path(tempfile.mkdtemp(prefix="daemon-", dir=root))
    for package in source.iterdir():
        if package.is_dir() and package.name != "albedo":
            (out / package.name).symlink_to(package)
    albedo = out / "albedo"
    (albedo / "priv").mkdir(parents=True)
    (albedo / "ebin").symlink_to(source / "albedo" / "ebin")
    priv = (source / "albedo" / "priv").resolve()
    for entry in priv.iterdir():
        if entry.name == "python":
            shutil.copytree(
                entry,
                albedo / "priv" / "python",
                ignore=shutil.ignore_patterns("__pycache__"),
            )
        else:
            (albedo / "priv" / entry.name).symlink_to(entry)
    launcher = out / "albedo-daemon"
    launcher.write_text(
        "#!/bin/sh\n"
        f"exec erl -pa {out}/*/ebin -eval 'albedo@@main:run(albedo)' -noshell -extra\n"
    )
    launcher.chmod(0o755)
    return launcher, albedo / "priv" / "python"


@exclusive
class KernelUpgradeTests(unittest.TestCase):
    bundle: Path

    def setUp(self):
        self.cells = []

        def script(request):
            if request["input"][-1].get("role") == "user" and self.cells:
                return python(self.cells.pop(0))
            return text("ok")

        def prepare(app):
            launcher, self.bundle = editable_daemon(app.root)
            app.env["ALBEDO_DAEMON"] = str(launcher)

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.session = self.app.session()

    def cell(self, code):
        """Run one cell through a model turn; its result and the turn's prompt."""
        self.cells.append(code)
        self.app.prompt(self.session, "run it").close()
        self.app.idle(self.session)
        results = [
            json.loads(event["result"])
            for event in self.app.events(self.session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ]
        request = next(
            r["request"]
            for r in reversed(self.provider.requests)
            if any(i.get("role") == "user" for i in r["request"]["input"])
        )
        prompt = [i["content"] for i in request["input"] if i.get("role") == "user"][-1]
        return results[-1], prompt

    def stale(self):
        with self.app.api(f"/sessions/{self.session}/status") as response:
            return json.load(response)["kernel"]["stale"]

    def edit_bundle(self):
        with (self.bundle / "albedo_bundle.py").open("a") as source:
            source.write(MARKER)

    def probe(self):
        return self.cell(
            "import albedo_bundle, os\n(survivor, getattr(albedo_bundle, 'MARKER', None), os.getpid())"
        )

    def test_restart_onto_a_new_bundle_swaps_the_kernel_and_keeps_variables(self):
        first, _ = self.cell("import os\nsurvivor = 41\nos.getpid()")
        self.edit_bundle()
        self.app.restart()
        swapped, prompt = self.probe()
        self.assertEqual(swapped.get("status"), "ok", swapped)
        survivor, marker, pid = swapped["value"].strip("()").split(", ")
        self.assertEqual((survivor, marker), ("41", "'new bundle'"), swapped)
        self.assertNotEqual(pid, first["value"])
        self.assertIn("The python kernel was upgraded to the new python bundle", prompt)
        # the restored names include `os`, re-imported from source
        self.assertRegex(prompt, r"Restored: [^.]*\bsurvivor\b")
        self.assertFalse(self.stale())

    def test_a_live_job_holds_the_old_kernel_until_it_ends(self):
        self.cell("import os\nsurvivor = 41\nj = run('sleep', '4')\nos.getpid()")
        self.edit_bundle()
        self.app.restart()
        held, _ = self.probe()
        self.assertIn("None", held["value"], "the old kernel must still run")
        self.assertTrue(self.stale())
        deadline = time.monotonic() + 30
        while self.stale() and time.monotonic() < deadline:
            # The job's wake is the idle moment that swaps the kernel.
            time.sleep(0.2)
        self.app.idle(self.session)
        swapped, _ = self.probe()
        self.assertIn("'new bundle'", swapped["value"])
        self.assertTrue(swapped["value"].startswith("(41,"), swapped)

    def test_kernel_upgrade_forces_the_swap_past_a_live_job(self):
        self.cell("import os\nsurvivor = 41\nj = run('sleep', '60')\nos.getpid()")
        self.edit_bundle()
        self.app.restart()
        with self.app.api(
            f"/sessions/{self.session}/commands",
            {"name": "/kernel", "arguments": "upgrade"},
        ) as response:
            result = json.load(response)["result"]
        self.assertEqual(result["jobs"], 1, result)
        swapped, _ = self.probe()
        self.assertIn("'new bundle'", swapped["value"])
        self.assertTrue(swapped["value"].startswith("(41,"), swapped)
        self.assertFalse(self.stale())


if __name__ == "__main__":
    unittest.main()
