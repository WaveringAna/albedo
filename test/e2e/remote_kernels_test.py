"""Sessions whose kernel lives on another host, reached over ssh.

The daemon's PATH holds a loopback ssh that runs each command locally under
its own "remote" HOME, so remote paths, the staged bundle and the run
directories are all distinct from the daemon's. Hosts named `oldhost`,
`locked` and `gone` stand for a python that is too old, a host that needs a
person to sign in, and one that cannot be reached.
"""

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import unittest
import urllib.error
import urllib.parse
from pathlib import Path

from harness import Albedo, Provider, exclusive, python, text

FAKE_SSH = """#!/bin/sh
printf '%s\\n' "$*" >> {log}
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
target=$1
shift
if [ "$target" = fakehost ] && [ -e {down} ]; then
  echo "ssh: connect to host fakehost port 22: Operation timed out" >&2
  exit 255
fi
case "$target" in
  gone) echo "ssh: connect to host gone port 22: Connection refused" >&2; exit 255 ;;
  locked) echo "locked: Permission denied (publickey)." >&2; exit 255 ;;
  slow-*) sleep 3; echo "ssh: connect to host $target port 22: Connection refused" >&2; exit 255 ;;
esac
path={bin}:/usr/bin:/bin
[ "$target" = oldhost ] && path={old}:$path
exec env -i HOME={home} PATH="$path" SHELL={bin}/loginsh /bin/sh -c "$*"
"""

# A login shell whose "profile" greets on stdout, as many do, and sources
# nothing else: /etc/profile would put the system python ahead of the fake
# host's. Every scenario runs through it, so a greeting must never reach a
# framed stream.
LOGIN_SHELL = """#!/bin/sh
if [ "$1" = -l ]; then
  shift
  echo "welcome to the fake host"
fi
exec /bin/sh "$@"
"""

# The daemon's own python3, logging what it runs, so a test can tell that a
# termination ladder never ran on this machine.
LOCAL_PYTHON = """#!/bin/sh
printf '%s\\n' "$*" >> {log}
exec {python} "$@"
"""


def write(path, content):
    path.write_text(content)
    path.chmod(0o755)


def processes(*needles):
    """Pids whose command line holds every needle."""
    listing = subprocess.run(
        ["ps", "-axo", "pid=,command="], capture_output=True, text=True, check=True
    ).stdout
    return [
        int(line.split(None, 1)[0])
        for line in listing.splitlines()
        if all(needle in line for needle in needles)
    ]


@exclusive
class RemoteKernelTests(unittest.TestCase):
    remote_home: Path
    ssh_log: Path
    python_log: Path
    down: Path

    def setUp(self):
        self.cells = []

        def script(request):
            if request["input"][-1].get("role") == "user" and self.cells:
                return python(self.cells.pop(0))
            return text("ok")

        def prepare(app):
            root = app.root
            self.remote_home = root / "remote-home"
            self.remote_home.mkdir()
            self.ssh_log = root / "ssh.log"
            self.python_log = root / "local-python.log"
            self.down = root / "fakehost-down"
            real = shutil.which("python3") or sys.executable
            local, remote, old = (
                root / "local-bin",
                root / "remote-bin",
                root / "old-bin",
            )
            for directory in (local, remote, old):
                directory.mkdir()
            write(
                local / "ssh",
                FAKE_SSH.format(
                    log=self.ssh_log,
                    bin=remote,
                    old=old,
                    home=self.remote_home,
                    down=self.down,
                ),
            )
            write(
                local / "python3", LOCAL_PYTHON.format(log=self.python_log, python=real)
            )
            write(remote / "loginsh", LOGIN_SHELL)
            os.symlink(real, remote / "python3")
            for tool in ("git", "jj"):
                found = shutil.which(tool)
                if found:
                    os.symlink(found, remote / tool)
            ssh_config = root / "user-home" / ".ssh"
            ssh_config.mkdir()
            (ssh_config / "config").write_text(
                "Host configured-box\n  User someone\nHost *\n  ServerAliveInterval 30\n"
                "Include extra.conf\n"
            )
            (ssh_config / "extra.conf").write_text("Host included-box other-*\n")
            write(old / "python3", "#!/bin/sh\necho 3.9\n")
            app.daemon.env["PATH"] = f"{local}{os.pathsep}{app.daemon.env['PATH']}"

        self.provider = Provider(script)
        self.addCleanup(self.provider.close)
        self.app = Albedo(self.provider, protocol="responses", prepare=prepare)
        self.app.__enter__()
        self.addCleanup(self.app.__exit__, None, None, None)
        self.project = self.remote_home / "proj"
        self.project.mkdir()

    def create(self, workspace):
        with self.app.api(
            "/sessions", {"workspace": workspace, "provider": self.app.profile}
        ) as response:
            return json.load(response)

    def cell(self, session, code, *, during=None):
        """Run one cell through a model turn and return its tool result."""
        self.cells.append(code)
        self.app.prompt(session, "run it").close()
        if during:
            during()
        self.app.idle(session, timeout=60)
        results = [
            json.loads(event["result"])
            for event in self.app.events(session)
            if event.get("type") == "tool" and event.get("name") == "python"
        ]
        return results[-1]

    def test_a_remote_kernel_runs_in_the_remote_folder_from_the_staged_bundle(self):
        session = self.create(f"fakehost:{self.project}")["id"]
        result = self.cell(
            session,
            "import os, albedo_bundle\n(os.getcwd(), os.environ['HOME'], str(albedo_bundle.ROOT))",
        )
        self.assertEqual(result["status"], "ok", result)
        cwd, home, bundle = eval(result["value"])
        self.assertEqual(os.path.realpath(cwd), os.path.realpath(self.project))
        self.assertEqual(home, str(self.remote_home))
        self.assertTrue(
            bundle.startswith(f"{os.path.realpath(self.remote_home)}/.albedo-remote/")
            or bundle.startswith(f"{self.remote_home}/.albedo-remote/"),
            bundle,
        )
        # The model is told where it runs.
        system = json.dumps(self.provider.requests[0]["request"])
        self.assertIn("execute on fakehost (", system)

    def test_a_bridge_killed_mid_cell_reattaches_over_ssh(self):
        session = self.create(f"fakehost:{self.project}")["id"]
        first = self.cell(session, "import os\nos.getpid()")
        (bridge,) = processes(f"{self.remote_home}/.albedo-remote/", "albedo_bridge.py")

        def kill_bridge():
            time.sleep(1)
            os.kill(bridge, signal.SIGKILL)

        slept = self.cell(
            session,
            "import time\ntime.sleep(3)\nprint('woke')\nos.getpid()",
            during=kill_bridge,
        )
        self.assertEqual(slept["status"], "ok", slept)
        self.assertEqual(slept["output"].strip(), "woke")
        self.assertEqual(slept["value"], first["value"])
        bridges = [
            line
            for line in self.ssh_log.read_text().splitlines()
            if "albedo_bridge.py" in line
        ]
        self.assertGreaterEqual(len(bridges), 2, "the reattach did not go over ssh")

    def test_a_remote_kernel_outlives_a_daemon_restart(self):
        session = self.create(f"fakehost:{self.project}")["id"]
        first = self.cell(session, "import os\nsurvivor = 41\nos.getpid()")
        self.app.restart(crash=True)
        after = self.cell(session, "survivor += 1\n(survivor, os.getpid())")
        self.assertEqual(after["value"], f"(42, {first['value']})")

    def test_a_kernel_survives_ssh_being_down_while_the_daemon_restarts(self):
        session = self.create(f"fakehost:{self.project}")["id"]
        first = self.cell(session, "import os\nsurvivor = 41\nos.getpid()")
        self.down.touch()
        # Back a few seconds after the daemon came up, while its startup
        # attach and the turn's are still failing.
        threading.Timer(4, self.down.unlink).start()
        self.app.restart(crash=True)
        after = self.cell(session, "survivor += 1\n(survivor, os.getpid())")
        self.assertEqual(after["value"], f"(42, {first['value']})")

    def test_a_remote_sessions_memory_is_the_daemons_and_links_with_a_local_one(self):
        remote = f"fakehost:{self.project}"
        session = self.create(remote)["id"]
        self.cell(session, "memory.append('the gate runs on fakehost')")
        slug = re.sub(r"[^A-Za-z0-9]", "-", remote)
        written = self.app.home / "memories" / slug / "memory.md"
        self.assertEqual(written.read_text(), "the gate runs on fakehost\n")
        self.assertFalse((self.remote_home / ".albedo").exists())

        # The same project checked out here, linked: it reads the remote one.
        checkout = self.app.root / "checkout"
        checkout.mkdir()
        local = self.create(str(checkout))["id"]
        with self.app.api(
            f"/sessions/{local}/commands",
            {"name": "/link", "args": {"action": "add", "details": remote}},
        ) as response:
            self.assertIn("linked with", json.load(response)["result"]["message"])
        found = self.cell(local, "print(memory.grep('gate'))")
        self.assertIn(f"[{remote}] memory.md:1: the gate runs", found["output"])

    def test_a_linked_remote_folder_is_checked_on_its_host(self):
        checkout = self.app.root / "checkout"
        checkout.mkdir()
        local = self.create(str(checkout))["id"]

        def link(**args):
            with self.app.api(
                f"/sessions/{local}/commands", {"name": "/link", "args": args}
            ) as response:
                return json.load(response)["result"]

        def badges():
            rows = link()["page"]["rows"][1:]
            return {row["id"]: (row["badge"], row["detail"]) for row in rows}

        present = f"fakehost:{self.project}"
        missing = f"fakehost:{self.remote_home}/missing"
        for member in (present, missing, "gone:/srv/app"):
            link(action="add", details=member)
        found = badges()
        self.assertEqual(found[present], ("", ""))
        self.assertEqual(found[missing][0], "gone")
        badge, detail = found["gone:/srv/app"]
        self.assertEqual(badge, "unreachable")
        self.assertIn("Connection refused", detail)

        # A host that stops answering is not a gone folder.
        self.down.touch()
        found = badges()
        self.assertEqual(found[present][0], "unreachable")
        self.assertEqual(found[missing][0], "unreachable")
        self.down.unlink()

        # A session opening with the host's probe fresh is told what is gone.
        self.cell(self.create(str(checkout))["id"], "1")
        instructions = self.provider.requests[-1]["request"]["instructions"]
        self.assertIn(f"{missing} (its folder is gone)", instructions)
        self.assertNotIn(f"{present} (its folder is gone)", instructions)

    def test_linked_hosts_are_checked_side_by_side(self):
        checkout = self.app.root / "slow-checkout"
        checkout.mkdir()
        local = self.create(str(checkout))["id"]

        def link(**args):
            with self.app.api(
                f"/sessions/{local}/commands", {"name": "/link", "args": args}
            ) as response:
                return json.load(response)["result"]

        for host in ("slow-a", "slow-b"):
            link(action="add", details=f"{host}:/srv")
        # Each host takes 3 s to refuse; one after the other would be 6.
        began = time.monotonic()
        rows = link()["page"]["rows"][1:]
        self.assertLess(time.monotonic() - began, 5.5)
        self.assertEqual([row["badge"] for row in rows], ["unreachable"] * 2)

    def test_a_remote_home_is_resolved_and_stored_absolute(self):
        created = self.create("fakehost:~/proj")
        self.assertEqual(created["workspace"], f"fakehost:{self.project}")
        with self.assertRaises(urllib.error.HTTPError) as refused:
            self.create("gone:~/proj")
        self.assertEqual(refused.exception.code, 400)
        self.assertIn("Connection refused", refused.exception.read().decode())

    def test_hosts_report_what_ssh_found(self):
        def warm(host):
            with self.app.api(f"/hosts/{host}/warm", {}) as response:
                return json.load(response)

        ready = warm("fakehost")
        self.assertEqual(ready["state"], "ready", ready)
        self.assertEqual(ready["home"], str(self.remote_home))
        self.assertTrue(ready["os"] and ready["arch"])
        old = warm("oldhost")
        self.assertEqual(old["state"], "unsupported", old)
        self.assertIn("python >= 3.11", old["detail"])
        self.assertEqual(warm("locked")["state"], "needs_auth")
        self.assertEqual(warm("gone")["state"], "unreachable")
        with self.app.api("/hosts/fakehost") as response:
            self.assertEqual(json.load(response)["state"], "ready")

        # A turn at a host that needs a sign-in waits with ssh's words, and
        # the host names the control path the tui's sign-in opens.
        session = self.create("locked:/srv/app")["id"]
        with self.app.prompt(session, "hello") as response:
            operation = json.load(response)["operationId"]
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with self.app.api(f"/operations/{operation}") as response:
                receipt = json.load(response)
            if receipt["blockingReason"]:
                break
            time.sleep(0.05)
        self.assertEqual(receipt["deliveryStatus"], "pending", receipt)
        self.assertIn("Permission denied", receipt["blockingReason"] or "")
        with self.app.api("/hosts/locked") as response:
            host = json.load(response)
        self.assertEqual(host["state"], "needs_auth", host)
        self.assertTrue(host["control_path"].endswith("/%C"), host)

    def test_a_remote_kernel_is_ended_on_its_host_never_here(self):
        session = self.create(f"fakehost:{self.project}")["id"]
        started = self.cell(
            session,
            "import asyncio\njob = run('sleep', '7777')\nawait asyncio.sleep(0.5)\njob.exit_code",
        )
        self.assertEqual(started["status"], "ok", started)
        self.assertTrue(processes("sleep 7777"))
        elsewhere = self.remote_home / "elsewhere"
        elsewhere.mkdir()
        with self.app.api(
            f"/sessions/{session}/workspace", {"workspace": f"fakehost:{elsewhere}"}
        ):
            pass
        deadline = time.monotonic() + 15
        while processes("sleep 7777") and time.monotonic() < deadline:
            time.sleep(0.1)
        self.assertFalse(processes("sleep 7777"))
        remote_ladder = [
            line
            for line in self.ssh_log.read_text().splitlines()
            if "albedo_signal.py" in line
        ]
        self.assertTrue(remote_ladder, "the kernel was not ended over ssh")
        local = self.python_log.read_text() if self.python_log.exists() else ""
        self.assertNotIn("albedo_signal.py", local)

    def test_hosts_list_recent_and_configured_hosts_without_probing(self):
        self.create(f"fakehost:{self.project}")
        with self.app.api("/hosts") as response:
            hosts = json.load(response)["hosts"]
        by_host = {entry["host"]: entry for entry in hosts}
        self.assertEqual(by_host["fakehost"]["source"], "recent")
        self.assertEqual(by_host["configured-box"]["source"], "config")
        self.assertEqual(by_host["included-box"]["source"], "config")
        self.assertNotIn("*", by_host)
        self.assertFalse([host for host in by_host if "*" in host])
        # Nothing was probed just to list them.
        self.assertNotIn("state", by_host["configured-box"])

    def browse(self, route, path):
        query = urllib.parse.urlencode({"path": path})
        with self.app.api(f"/fs/{route}?{query}") as response:
            return json.load(response)

    def assert_same_answers(self, tree):
        """A remote folder reads exactly as the same folder read locally."""
        for route in ("list", "repo", "preview"):
            with self.subTest(route=route):
                remote = self.browse(route, f"fakehost:{tree}")
                local = self.browse(route, str(tree))
                if "path" in remote:
                    self.assertEqual(remote.pop("path"), f"fakehost:{tree}")
                    local.pop("path")
                if "home" in remote:
                    self.assertEqual(remote.pop("home"), f"fakehost:{self.remote_home}")
                    local.pop("home")
                self.assertEqual(remote, local)

    def make_tree(self, name):
        tree = self.remote_home / name
        (tree / "src" / "deep").mkdir(parents=True)
        (tree / "docs").mkdir()
        (tree / "src" / "main.py").write_text("print('hi')\n" * 40)
        (tree / "src" / "deep" / "util.go").write_text("package deep\n")
        (tree / "README.md").write_text("# tree\n")
        (tree / ".hidden").mkdir()
        return tree

    def test_a_remote_git_repo_browses_like_a_local_one(self):
        if not shutil.which("git"):
            self.skipTest("git is not installed")
        tree = self.make_tree("git-tree")
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@e", "-C", str(tree)]
        subprocess.run([*git, "init", "-q", "-b", "main"], check=True)
        subprocess.run([*git, "add", "src", "README.md"], check=True)
        subprocess.run([*git, "commit", "-qm", "one"], check=True)
        (tree / "docs" / "new.md").write_text("new\n")
        self.assertEqual(self.browse("repo", f"fakehost:{tree}")["repo"]["kind"], "git")
        self.assert_same_answers(tree)
        self.assert_same_answers(tree / "src")

    def test_a_remote_jj_repo_browses_like_a_local_one(self):
        if not shutil.which("jj"):
            self.skipTest("jj is not installed")
        tree = self.make_tree("jj-tree")
        env = {**os.environ, "JJ_USER": "t", "JJ_EMAIL": "t@e"}
        subprocess.run(["jj", "git", "init", "--quiet", str(tree)], check=True, env=env)
        subprocess.run(
            ["jj", "-R", str(tree), "bookmark", "create", "main", "-r", "@", "--quiet"],
            check=True,
            env=env,
        )
        self.assertEqual(self.browse("repo", f"fakehost:{tree}")["repo"]["kind"], "jj")
        self.assert_same_answers(tree)

    def test_a_remote_folder_answers_with_the_hosts_state(self):
        query = urllib.parse.urlencode({"path": "gone:/srv"})
        with self.assertRaises(urllib.error.HTTPError) as refused:
            self.app.api(f"/fs/list?{query}").close()
        self.assertEqual(refused.exception.code, 503)
        body = json.loads(refused.exception.read())
        self.assertEqual((body["host"], body["state"]), ("gone", "unreachable"))
        # A session there still composes, its project files skipped.
        session = self.create("gone:/srv/app")["id"]
        with self.app.api(f"/sessions/{session}/commands") as response:
            self.assertTrue(json.load(response))
        # A ~ path lists the remote home.
        listed = self.browse("list", "fakehost:~")
        self.assertEqual(listed["path"], f"fakehost:{self.remote_home}")
        self.assertIn("proj", [entry["name"] for entry in listed["entries"]])

    def test_project_instructions_and_skills_come_from_the_host(self):
        (self.project / "AGENTS.md").write_text("remote rule: always say banana\n")
        skill = self.project / ".agents" / "skills" / "far-skill"
        skill.mkdir(parents=True)
        (skill / "SKILL.md").write_text(
            "---\nname: far-skill\ndescription: a skill that lives on the host\n---\nbody\n"
        )
        session = self.create(f"fakehost:{self.project}")["id"]
        self.app.prompt(session, "hello").close()
        self.app.idle(session, timeout=60)
        request = json.dumps(self.provider.requests[-1]["request"])
        self.assertIn("always say banana", request)
        self.assertIn("a skill that lives on the host", request)
        self.assertNotIn("aren't available yet", request)


if __name__ == "__main__":
    unittest.main()
