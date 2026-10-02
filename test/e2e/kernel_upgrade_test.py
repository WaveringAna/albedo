"""A stale kernel is swapped for a current one, namespace included.

After a daemon restart the reattached kernel may run an older python bundle,
have booted with another module set than its session has now, or speak another
session protocol. At the session's next idle moment it is replaced by a current
kernel, its variables carried through a snapshot and a restore. A live job
holds an older bundle or module set until it ends; a kernel on another protocol
goes at once, its outbox dropped rather than replayed, carrying nothing when
its snapshot fails, and its process group ends either way.
"""

import json
import os
from pathlib import Path
import shutil
import sqlite3
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


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


class Swaps(unittest.TestCase):
    """Cells through model turns against one session, on a daemon that may run
    an editable copy of the python bundle."""

    bundle: Path

    def boot(self, *, editable):
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
        self.app = Albedo(
            self.provider, protocol="responses", prepare=prepare if editable else None
        )
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

    def kernel(self):
        with self.app.api(f"/sessions/{self.session}/status") as response:
            return json.load(response)["kernel"]

    def stale(self):
        return self.kernel()["stale"]

    def wait_until_current(self):
        deadline = time.monotonic() + 30
        while self.stale() and time.monotonic() < deadline:
            # The job's wake is the idle moment that swaps the kernel.
            time.sleep(0.2)
        self.app.idle(self.session)


# exclusive: boots an editable Python bundle and restarts the daemon
@exclusive
class KernelUpgradeTests(Swaps):
    def setUp(self):
        self.boot(editable=True)

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
        self.wait_until_current()
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


# exclusive: restarts the daemon and changes global extension enablement
@exclusive
class ModuleSkewTests(Swaps):
    """The session's module set changes while the daemon is down: disabling
    skills drops the `skills` module the recorded kernel booted with."""

    def setUp(self):
        self.boot(editable=False)

    def drop_skills(self, app):
        settings = json.loads((app.home / "extensions.json").read_text())
        settings.setdefault("enabled", {})["skills"] = False
        (app.home / "extensions.json").write_text(json.dumps(settings))

    def probe(self):
        return self.cell("import os\n(survivor, 'skills' in globals(), os.getpid())")

    def test_a_changed_module_set_swaps_the_kernel_and_keeps_variables(self):
        first, _ = self.cell(
            "import os\nsurvivor = 41\n('skills' in globals(), os.getpid())"
        )
        self.assertTrue(first["value"].startswith("(True,"), first)
        self.app.restart(prepare=self.drop_skills)
        swapped, prompt = self.probe()
        self.assertEqual(swapped.get("status"), "ok", swapped)
        survivor, skills, pid = swapped["value"].strip("()").split(", ")
        self.assertEqual((survivor, skills), ("41", "False"), swapped)
        self.assertNotEqual(pid, first["value"].strip("()").split(", ")[1])
        self.assertIn(
            "The python kernel was upgraded to the session's new extension modules",
            prompt,
        )
        self.assertRegex(prompt, r"Restored: [^.]*\bsurvivor\b")
        self.assertFalse(self.stale())

    def test_a_live_job_holds_the_old_module_set_until_it_ends(self):
        self.cell("import os\nsurvivor = 41\nj = run('sleep', '4')")
        self.app.restart(prepare=self.drop_skills)
        held, _ = self.probe()
        self.assertTrue(held["value"].startswith("(41, True,"), held)
        self.assertEqual(self.kernel().get("reason"), "modules")
        self.wait_until_current()
        swapped, _ = self.probe()
        self.assertTrue(swapped["value"].startswith("(41, False,"), swapped)


# exclusive: restarts the daemon and edits its kernel outbox offline
@exclusive
class ProtocolSkewTests(Swaps):
    """The kernel's session layer is told to speak protocol 2 from inside a
    cell, so the hello it gives the restarted daemon differs from the
    bridge's protocol 1, as an older kernel's would; its bundle stays current."""

    def setUp(self):
        self.boot(editable=False)

    def start(self):
        """Variables and a long job in the old kernel: its pid and the job's."""
        started, _ = self.cell(
            "import albedo_link, asyncio, os\nalbedo_link.PROTOCOL = 2\n"
            "survivor = 41\nj = run('sleep', '60')\n"
            "await asyncio.sleep(0.5)\n(os.getpid(), j.process.pid)"
        )
        kernel, job = (int(part) for part in started["value"].strip("()").split(","))
        return kernel, job

    def restart_current(self, *, unsaveable=False):
        """Restart onto protocol 1 with a frame for the old kernel waiting in
        the daemon's outbox; it would leave `replayed` behind if it ran."""
        marker = self.app.root / "replayed"

        def prepare(app):
            with sqlite3.connect(app.home / "albedo.sqlite") as db:
                kernel, run_dir, seq = db.execute(
                    "SELECT kernel, run_dir, out_seq + 1 FROM kernel_links WHERE session=?",
                    (self.session,),
                ).fetchone()
                frame = {
                    "type": "execute",
                    "id": "left-in-the-outbox",
                    "code": f"open({str(marker)!r}, 'w').close()",
                    "durable": False,
                    "max_edge": 0,
                }
                db.execute(
                    "INSERT INTO kernel_outbox (session, kernel, seq, frame) VALUES (?,?,?,?)",
                    (self.session, kernel, seq, json.dumps(frame)),
                )
                db.execute(
                    "UPDATE kernel_links SET out_seq=? WHERE kernel=?", (seq, kernel)
                )
            if unsaveable:
                # A directory where the snapshot is written: the save fails.
                (Path(run_dir) / "namespace.state" / "taken").mkdir(parents=True)

        self.app.restart(prepare=prepare)
        return marker

    def probe(self):
        return self.cell("import os\n(globals().get('survivor'), os.getpid())")

    def assert_gone(self, marker, *pids):
        """The old kernel and its job ended, its outbox dropped unreplayed."""
        deadline = time.monotonic() + 15
        while any(alive(pid) for pid in pids) and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse([pid for pid in pids if alive(pid)], "the old kernel lives on")
        self.assertFalse(marker.exists(), "the old outbox was replayed")
        with sqlite3.connect(self.app.home / "albedo.sqlite") as db:
            (left,) = db.execute(
                "SELECT count(*) FROM kernel_outbox"
                " WHERE CAST(frame AS TEXT) LIKE '%left-in-the-outbox%'"
            ).fetchone()
        self.assertEqual(left, 0)

    def test_another_protocol_swaps_past_live_jobs_and_drops_the_outbox(self):
        kernel, job = self.start()
        marker = self.restart_current()
        swapped, prompt = self.probe()
        self.assertEqual(swapped.get("status"), "ok", swapped)
        survivor, pid = swapped["value"].strip("()").split(", ")
        self.assertEqual(survivor, "41", swapped)
        self.assertNotEqual(int(pid), kernel)
        self.assertIn(
            "The python kernel was upgraded to the current kernel protocol", prompt
        )
        self.assertFalse(self.stale())
        self.assert_gone(marker, kernel, job)

    def test_a_bundle_out_of_step_with_the_daemon_refuses_to_boot(self):
        """A python bundle on another protocol than the daemon's own makes
        every fresh kernel stale at birth: the boot fails and says why,
        instead of swapping one fresh kernel for another forever."""

        def prepare(app):
            launcher, bundle = editable_daemon(app.root)
            app.env["ALBEDO_DAEMON"] = str(launcher)
            link = bundle / "albedo_link.py"
            link.write_text(link.read_text().replace("PROTOCOL = 1", "PROTOCOL = 2", 1))

        self.app.restart(prepare=prepare)
        started = time.monotonic()
        with self.app.prompt(self.session, "run it") as response:
            operation = json.load(response)["operationId"]
        self.app.idle(self.session)
        self.assertLess(time.monotonic() - started, 10)
        # The input waits, blocked with the reason, rather than lost.
        with self.app.api(f"/operations/{operation}") as response:
            receipt = json.load(response)
        self.assertIn("out of step", receipt["blockingReason"] or "", receipt)
        self.assertIn("protocol", receipt["blockingReason"])
        with self.app.api(f"/sessions/{self.session}/status") as response:
            self.assertEqual(json.load(response)["kernel"]["link"], "none")

    def test_another_protocol_whose_snapshot_fails_is_swapped_carrying_nothing(self):
        kernel, job = self.start()
        marker = self.restart_current(unsaveable=True)
        swapped, prompt = self.probe()
        self.assertEqual(swapped.get("status"), "ok", swapped)
        self.assertTrue(swapped["value"].startswith("(None,"), swapped)
        self.assertIn("No variables were restored", prompt)
        self.assertIn("Not carried: namespace", prompt)
        self.assertFalse(self.stale())
        self.assert_gone(marker, kernel, job)


if __name__ == "__main__":
    unittest.main()
