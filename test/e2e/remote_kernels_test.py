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
import shlex
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

from harness import Albedo, Provider, exclusive, operation_id, python, text

FAKE_SSH = """#!/bin/sh
printf '%s\\n' "$*" >> {log}
query=
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    -G) query=1; shift ;;
    -*) shift ;;
    *) break ;;
  esac
done
target=$1
shift
if [ -n "$query" ]; then
  # ssh -G only reads the config: muxed's names a ControlPath, no other does
  if [ "$target" = muxed ]; then
    echo "controlmaster auto"
    echo "controlpath {mux}"
    echo "controlpersist 1800"
  fi
  exit 0
fi
if [ "$target" = fakehost ] && [ -e {down} ]; then
  echo "ssh: connect to host fakehost port 22: Operation timed out" >&2
  exit 255
fi
case "$target" in
  gone) echo "ssh: connect to host gone port 22: Connection refused" >&2; exit 255 ;;
  locked) echo "locked: Permission denied (publickey)." >&2; exit 255 ;;
  slow-*) sleep 3; echo "ssh: connect to host $target port 22: Connection refused" >&2; exit 255 ;;
esac
case "$*" in
  *.part.*) [ -e {slow} ] && sleep 3 ;;
esac
path={path}
[ "$target" = oldhost ] && path={old}:$path
exec env -i HOME={home} PATH="$path" SHELL={bin}/loginsh /bin/sh -c "$*"
"""

# A login shell whose "profile" greets on stdout and stderr, as many do, and
# sources nothing else: /etc/profile would put the system python ahead of the
# fake host's. Every scenario runs through it, so a greeting must never reach
# a framed stream, nor the daemon's log.
LOGIN_SHELL = """#!/bin/sh
if [ "$1" = -l ]; then
  shift
  echo "welcome to the fake host"
  echo "you have no mail" >&2
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


# exclusive: sets daemon PATH for loopback SSH and local Python wrappers
@exclusive
class RemoteKernelTests(unittest.TestCase):
    remote_home: Path
    ssh_log: Path
    mux: Path
    python_log: Path
    down: Path
    slow_stage: Path

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
            self.slow_stage = root / "slow-stage"
            self.mux = root / "cm-muxed"
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
                    slow=self.slow_stage,
                    mux=self.mux,
                    path=shlex.quote(f"{remote}{os.pathsep}{app.daemon.env['PATH']}"),
                ),
            )
            write(
                local / "python3", LOCAL_PYTHON.format(log=self.python_log, python=real)
            )
            write(remote / "loginsh", LOGIN_SHELL)
            os.symlink(real, remote / "python3")
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
        session = operation_id()
        with self.app.api(
            f"/sessions/{session}",
            {
                "kind": "new",
                "workspace": workspace,
                "provider_profile": self.app.profile,
            },
            method="PUT",
            headers={"If-None-Match": "*"},
        ) as response:
            return json.load(response)

    def host(self, target):
        query = urllib.parse.urlencode({"target": target})
        with self.app.api("/hosts?" + query) as response:
            [host] = json.load(response)["items"]
        self.assertEqual(host["target"], target)
        return host

    def group(self, workspace):
        query = urllib.parse.urlencode({"workspace": str(workspace)})
        with self.app.api(f"/extensions/links/groups?{query}") as response:
            return json.load(response)

    def merge(self, workspace, other):
        group = self.group(workspace)["configuration_resource"]
        target = self.group(other)["configuration_resource"]
        with self.app.api(
            group["url"],
            {"other_workspace": str(other), "other_etag": target["etag"]},
            headers={"If-Match": group["etag"]},
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
            json.loads(part["value"])
            for entry in self.app.history(session)["items"]
            if entry["kind"] == "tool_result" and entry["tool"]["name"] == "python"
            for part in entry["content"]
            if part["kind"] == "json" and part["field"] == "result"
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
        log = (self.app.home / "daemon.log").read_text(errors="replace")
        self.assertNotIn("welcome to the fake host", log)
        self.assertNotIn("you have no mail", log)

    def test_remote_job_output_is_not_a_silently_shortened_patch(self):
        session = self.create(str(self.app.workspace))["id"]
        result = self.cell(
            session,
            r"""import sys
rem = await remote.connect('fakehost')
fallback = await remote.connect('oldhost')
starts = [('local', run), ('remote', rem.run), ('fallback', fallback.run)]
expected = ('first file\n' + 'line αβ\n' * 5000 + 'second file\n' + 'other line\n' * 8000).encode()
program = "import sys; sys.stdout.buffer.write(('first file\\n' + 'line αβ\\n' * 5000 + 'second file\\n' + 'other line\\n' * 8000).encode())"
for label, start in starts:
    job = start(sys.executable, '-c', program)
    await job
    assert job.tail(60000) == expected.decode()[-60000:], label
    assert await job.head(40000) == expected.decode()[:40000], label
    assert await job.read() == expected.decode(), label
    assert job.tail(65536) == expected.decode()[-65536:], label
    assert await job.read(offset=17, limit=4000) == expected[17:4017].decode(errors='ignore'), label
    # Byte offsets remain byte offsets, even when a page cuts through UTF-8.
    offset = expected.index('α'.encode()) + 1
    assert await job.read(offset=offset, limit=9) == expected[offset:offset+9].decode(errors='ignore'), label
    for preview in (job.head, job.tail):
        try:
            await preview(3_000_000)
        except Exception as error:
            assert 'job.read()' in str(error) and 'job.save' in str(error), str(error)
        else:
            raise AssertionError('silently shortened a preview: ' + label)
    path = await job.save(label + '.patch')
    actual = await rem.read(path) if label == 'remote' else Path(path).read_bytes()
    if isinstance(actual, str):
        actual = actual.encode()
    assert actual == expected, label

async def refuses(call, *args, message, **kwargs):
    try:
        await call(*args, **kwargs)
    except Exception as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError('accepted incomplete output')

for label, start in starts:
    job = start(sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'begin\\xff\\x00' + b'x' * 140000 + b'end')")
    await job
    assert '\ufffd' in await job.read(), label
    assert await job.tail(0) == '' and await job.head(lines=0) == '', label
    await refuses(job.read, limit=65537, message='65536')
    # No newline in the window: a line request must not return a fragment.
    await refuses(job.tail, lines=1, message='job.read()')
    await refuses(job.head, lines=1, message='job.read()')
    path = await job.save(label + '.bin')
    actual = await rem.read(path) if label == 'remote' else Path(path).read_bytes()
    assert actual == b'begin\xff\x00' + b'x' * 140000 + b'end', label
    overflow = start(sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'z' * (2097152 + 10) + b'\\xff\\x00end')")
    await overflow
    await refuses(overflow.read, message='paginate with')
    assert await overflow.read(offset=1048576, limit=10) == 'z' * 10, label
    assert await overflow.read(offset=1048576-2, limit=10) == 'z' * 10, label
    page_reader = rem.output.read if label == 'remote' else output.read
    assert await page_reader(overflow.id, offset=1048576, limit=10) == 'z' * 10, label
    pages = [await overflow.read(offset=offset, limit=65536)
             for offset in range(0, 2097152 + 15, 65536)]
    assert ''.join(pages) == 'z' * (2097152 + 10) + '\x00end', label
    assert await overflow.read(offset=2097152+15, limit=65536) == '', label
    await overflow.save(path)
    saved = await rem.read(path) if label == 'remote' else Path(path).read_bytes()
    assert saved == b'z' * (2097152 + 10) + b'\xff\x00end', label
    # The disk cap is explicit; stored pages remain accessible, lost pages refuse.
    capped = start(sys.executable, '-c', "import sys; sys.stdout.buffer.write(b'c' * (16777216 + 1))")
    await capped
    assert await capped.read(offset=16777217, limit=0) == '', label
    await refuses(capped.read, message='refusing incomplete output')
    await refuses(capped.save, path, message='refusing incomplete output')
    preserved = await rem.read(path) if label == 'remote' else Path(path).read_bytes()
    assert preserved == saved, 'overwrote destination with partial output: ' + label
    assert await capped.read(offset=16777216-10, limit=10) == 'c' * 10, label
    await refuses(capped.read, offset=16777216, limit=1, message='cannot be recovered by pagination')
    await refuses(page_reader, capped.id, offset=16777216-2, limit=10, message='cannot be recovered by pagination')
    unicode = start(sys.executable, '-c', "print('é' * 70000, end='')")
    await unicode
    await refuses(unicode.tail, 60000, message='job.read()')
    await refuses(unicode.head, 60000, message='job.read()')
    assert await unicode.tail(100) == 'é' * 100, label

# A running job must not overwrite a completed artifact.
protected = Path('protected.bin')
protected.write_bytes(b'keep me')
running = run(sys.executable, '-c', 'import time; time.sleep(0.5)')
await refuses(running.read, message='await job')
await refuses(running.save, protected, message='await job')
assert protected.read_bytes() == b'keep me'
await running
# Streaming to a file recovers output larger than the retained buffers.
streamed = run(sys.executable, '-c', "print('s' * 2000000, end='')").pipe('tee', 'whole.txt')
await streamed
assert Path('whole.txt').read_bytes() == b's' * 2000000
# A failed atomic rename leaves the destination and no temporary output file.
directory = Path('not-a-file')
directory.mkdir()
(directory / 'keep').write_bytes(b'preserved')
before = set(Path('.').iterdir())
await refuses(running.save, directory, message='directory')
assert set(Path('.').iterdir()) == before
assert (directory / 'keep').read_bytes() == b'preserved'
print('refusals preserve destinations and exact binary output')

await rem.close()
await fallback.close()
print('complete output preserved for all three job kinds')
""",
        )
        self.assertEqual(result["status"], "ok", result)
        self.assertIn("complete output preserved", result["output"])
        self.assertIn("refusals preserve destinations", result["output"])

    def test_job_spill_is_live_and_failures_preserve_artifacts(self):
        session = self.create(str(self.app.workspace))["id"]
        result = self.cell(
            session,
            r"""import albedo_capture
import tempfile
import time
from unittest.mock import patch

async def refuses(call, *args, message, **kwargs):
    try:
        await call(*args, **kwargs)
    except Exception as error:
        assert message in str(error), str(error)
    else:
        raise AssertionError('accepted incomplete output')

protected = Path('protected-spill.bin')
protected.write_bytes(b'keep me')
release = Path('release-writer').absolute()
program = f'''import sys, time
from pathlib import Path
sys.stdout.buffer.write(b'x' * 2097152)
sys.stdout.flush()
while not Path({str(release)!r}).exists():
    time.sleep(0.01)
sys.stdout.buffer.write(b'end')
sys.stdout.flush()
'''
live = run(sys.executable, '-c', program)
async def ready():
    while live.capture.seen < 2097152:
        await asyncio.sleep(0.01)
await asyncio.wait_for(ready(), 5)
assert live.duration is None
assert live.read(offset=1048576-2, limit=10) == 'x' * 10
assert output.read(live.id, offset=2097152-10, limit=10) == 'x' * 10
await refuses(live.save, protected, message='await job')
assert protected.read_bytes() == b'keep me'
assert Path(live.capture.spill).stat().st_mode & 0o077 == 0

# Simulate a disk write failure after a valid spill prefix has been captured.
with patch.object(live.capture._spill_file, 'write', side_effect=OSError('disk full')):
    release.touch()
    await live
assert live.capture._spill_file is None
assert live.tail(3) == 'end'
await refuses(live.read, offset=1048576, limit=1, message='refusing incomplete output')
await refuses(live.save, protected, message='refusing incomplete output')
assert protected.read_bytes() == b'keep me'

# Creation failure keeps previews usable, and never retries from a lost prefix.
blocked = Path('not-a-spill-directory')
blocked.write_text('blocked')
with patch.object(albedo_capture, 'SPILL_DIR', str(blocked)):
    failed = run(sys.executable, '-c', "print('f' * 2097152, end='')")
    await failed
assert failed.tail(10) == 'f' * 10
assert failed.capture.spill is None
await refuses(failed.read, offset=1048576, limit=1, message='refusing incomplete output')
await refuses(failed.save, protected, message='refusing incomplete output')
assert protected.read_bytes() == b'keep me'

# A missing or shortened spill must not become a short page or a partial save.
for damage in ('shorten', 'remove'):
    job = run(sys.executable, '-c', "print('s' * 2097152, end='')")
    await job
    assert job.capture._spill_file is None
    spill = Path(job.capture.spill)
    if damage == 'shorten':
        spill.write_bytes(b'short')
    else:
        spill.unlink()
    before = set(Path('.').iterdir())
    await refuses(job.read, offset=1048576, limit=10,
                  message='incomplete' if damage == 'shorten' else 'No such file')
    await refuses(job.save, protected,
                  message='incomplete' if damage == 'shorten' else 'No such file')
    assert protected.read_bytes() == b'keep me'
    assert set(Path('.').iterdir()) == before

# Pruning deletes only expired spill files, not fresh files or directories.
with tempfile.TemporaryDirectory() as directory:
    old = Path(directory, 'old.txt')
    old.write_text('old')
    fresh = Path(directory, 'fresh.txt')
    fresh.write_text('fresh')
    nested = Path(directory, 'nested')
    nested.mkdir()
    (nested / 'keep.txt').write_text('keep')
    stale = time.time() - albedo_capture.SPILL_KEEP - 1
    os.utime(old, (stale, stale))
    os.utime(nested, (stale, stale))
    previous = albedo_capture.SPILL_DIR
    try:
        albedo_capture.prune_spills(directory)
    finally:
        albedo_capture.SPILL_DIR = previous
    assert not old.exists() and fresh.read_text() == 'fresh'
    assert (nested / 'keep.txt').read_text() == 'keep'
print('live spill pages, disk failures, atomic saves, and pruning verified')
""",
        )
        self.assertEqual(result["status"], "ok", result)
        self.assertIn("pruning verified", result["output"])

    def test_a_first_visit_says_it_is_copying_the_kernel(self):
        self.slow_stage.touch()  # each copy of the bundle takes 3 s
        session = self.create(f"fakehost:{self.project}")["id"]
        seen = set()

        def watch():
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                with self.app.api(f"/sessions/{session}?tail=0") as response:
                    kernel = json.load(response)["kernel"]
                seen.add(kernel["stage"])
                if kernel["state"] == "attached":
                    return
                time.sleep(0.2)

        result = self.cell(session, "1", during=watch)
        self.assertEqual(result["status"], "ok", result)
        self.assertIn("staging", seen)

    def test_a_bridge_killed_mid_cell_reattaches_over_ssh(self):
        session = self.create(f"fakehost:{self.project}")["id"]
        first = self.cell(session, "import os\nos.getpid()")
        (bridge,) = processes(f"{self.remote_home}/.albedo-remote/", "albedo_bridge.py")

        def kill_bridge():
            time.sleep(1)
            os.kill(bridge, signal.SIGKILL)

        slept = self.cell(
            session,
            "import threading\nthreading.Event().wait(3)\nprint('woke')\nos.getpid()",
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
        merged = self.merge(checkout, remote)
        self.assertIn(remote, merged["resource"]["value"]["members"])
        found = self.cell(local, "print(memory.grep('gate'))")
        self.assertIn(f"[{remote}] memory.md:1: the gate runs", found["output"])

    def test_a_linked_remote_folder_is_checked_on_its_host(self):
        checkout = self.app.root / "checkout"
        checkout.mkdir()
        self.create(str(checkout))

        def presence():
            return {
                item["workspace"]: item for item in self.group(checkout)["presence"]
            }

        present = f"fakehost:{self.project}"
        missing = f"fakehost:{self.remote_home}/missing"
        for member in (present, missing, "gone:/srv/app"):
            self.merge(checkout, member)
        found = presence()
        self.assertTrue(found[present]["exists"])
        self.assertFalse(found[missing]["exists"])
        self.assertEqual(found["gone:/srv/app"]["host"]["state"], "unreachable")
        self.assertIn(
            "Connection refused", found["gone:/srv/app"]["host"]["detail"]["detail"]
        )

        # A host that stops answering is not a gone folder.
        self.down.touch()
        found = presence()
        self.assertIsNone(found[present]["exists"])
        self.assertIsNone(found[missing]["exists"])
        with self.app.api("/hosts/fakehost/probe", {}) as response:
            self.assertEqual(response.status, 202)
        deadline = time.monotonic() + 15
        while (
            self.host("fakehost")["state"] == "probing" and time.monotonic() < deadline
        ):
            time.sleep(0.05)
        found = presence()
        self.assertEqual(found[present]["host"]["state"], "unreachable")
        self.assertEqual(found[missing]["host"]["state"], "unreachable")
        self.down.unlink()
        with self.app.api("/hosts/fakehost/probe", {}) as response:
            self.assertEqual(response.status, 202)
        deadline = time.monotonic() + 15
        while (
            self.host("fakehost")["state"] == "probing" and time.monotonic() < deadline
        ):
            time.sleep(0.05)
        self.assertEqual(self.host("fakehost")["state"], "ready")

        # A session opening with the host's probe fresh is told what is gone.
        self.cell(self.create(str(checkout))["id"], "1")
        instructions = self.provider.requests[-1]["request"]["instructions"]
        self.assertIn(f"{missing} (its folder is gone)", instructions)
        self.assertNotIn(f"{present} (its folder is gone)", instructions)

    def test_linked_hosts_are_checked_side_by_side(self):
        checkout = self.app.root / "slow-checkout"
        checkout.mkdir()
        self.create(str(checkout))

        for host in ("slow-a", "slow-b"):
            self.merge(checkout, f"{host}:/srv")
        # Each host takes 3 s to refuse; one after the other would be 6.
        began = time.monotonic()
        rows = [
            item
            for item in self.group(checkout)["presence"]
            if item["workspace"] != str(checkout)
        ]
        self.assertLess(time.monotonic() - began, 5.5)
        self.assertEqual([row["host"]["state"] for row in rows], ["unreachable"] * 2)

    def test_a_remote_home_is_resolved_and_stored_absolute(self):
        created = self.create("fakehost:~/proj")
        self.assertEqual(created["workspace"], f"fakehost:{self.project}")
        with self.assertRaises(urllib.error.HTTPError) as refused:
            self.create("gone:~/proj")
        self.assertEqual(refused.exception.code, 503)
        self.assertIn("Connection refused", refused.exception.read().decode())

    def test_hosts_report_what_ssh_found(self):
        def warm(host):
            with self.app.api(f"/hosts/{host}/probe", {}) as response:
                self.assertEqual(response.status, 202)
                observation = json.load(response)
            deadline = time.monotonic() + 15
            while observation["state"] == "probing" and time.monotonic() < deadline:
                time.sleep(0.05)
                observation = self.host(host)
            self.assertNotEqual(observation["state"], "probing", observation)
            return observation

        ready = warm("fakehost")
        self.assertEqual(ready["state"], "ready", ready)
        self.assertEqual(ready["home"], str(self.remote_home))
        self.assertTrue(ready["os"] and ready["architecture"])
        old = warm("oldhost")
        self.assertEqual(old["state"], "unsupported", old)
        self.assertIn("python >= 3.11", old["detail"]["detail"])
        self.assertEqual(warm("locked")["state"], "needs_auth")
        self.assertEqual(warm("gone")["state"], "unreachable")
        # A host whose ssh config names a ControlPath rides that master, so the
        # user's own ssh and albedo share one sign-in.
        self.assertEqual(warm("muxed")["state"], "ready")
        muxed = [
            line
            for line in self.ssh_log.read_text().splitlines()
            if " muxed " in line and "-G" not in line
        ]
        self.assertTrue(muxed)
        for line in muxed:
            self.assertIn(f"ControlPath={self.mux} ", line)
            self.assertIn("ControlPersist=1800 ", line)
        self.assertEqual(self.host("fakehost")["state"], "ready")

        # A bracketed IPv6 host travels percent-encoded in the probe's path and
        # is probed as itself, the same host a target query names.
        with self.app.api("/hosts/%5B::1%5D/probe", {}) as response:
            self.assertEqual(response.status, 202)
            self.assertEqual(json.load(response)["target"], "[::1]")
        self.host("[::1]")

        # A turn at a host that needs a sign-in waits with ssh's words, and
        # the host names the control path the tui's sign-in opens.
        session = self.create("locked:/srv/app")["id"]
        with self.app.prompt(session, "hello") as response:
            input_id = json.load(response)["id"]
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            with self.app.api(f"/sessions/{session}/inputs/{input_id}") as response:
                receipt = json.load(response)
            if receipt["blocking_reason"]:
                break
            time.sleep(0.05)
        self.assertEqual(receipt["delivery"], "pending", receipt)
        self.assertIn("Permission denied", receipt["blocking_reason"]["detail"])
        host = self.host("locked")
        self.assertEqual(host["state"], "needs_auth", host)
        self.assertTrue(host["authentication"]["control_path"].endswith("/%C"), host)

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
        with self.app.api(f"/sessions/{session}?view=configuration") as response:
            configuration = json.load(response)
            revision = response.headers["ETag"]
        self.app.api(
            f"/sessions/{session}?view=configuration",
            {
                "workspace": f"fakehost:{elsewhere}",
                "family_revision": configuration["family_revision"],
            },
            method="PATCH",
            headers={"If-Match": revision},
        ).close()
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
            hosts = json.load(response)["items"]
        by_host = {entry["target"]: entry for entry in hosts}
        self.assertTrue({"fakehost", "configured-box", "included-box"} <= set(by_host))
        self.assertNotIn("*", by_host)
        self.assertFalse([host for host in by_host if "*" in host])
        # Nothing was probed just to list them.
        self.assertEqual(by_host["configured-box"]["state"], "unknown")
        self.assertIsNone(by_host["configured-box"]["observed_at"])

    def browse(self, location, *, preview=False):
        query = {"location": str(location)}
        if preview:
            query["include"] = "preview"
        with self.app.api("/workspaces?" + urllib.parse.urlencode(query)) as response:
            return json.load(response)

    def assert_same_answers(self, tree):
        """Remote and local inspection preserve the same filesystem facts."""
        remote = self.browse(f"fakehost:{tree}", preview=True)
        local = self.browse(tree, preview=True)
        self.assertEqual(remote["directory"], f"fakehost:{tree}")
        self.assertEqual(remote["home"], f"fakehost:{self.remote_home}")
        self.assertEqual(
            [
                {key: row[key] for key in ("name", "vcs", "hidden", "modified_at")}
                for row in remote["items"]
            ],
            [
                {key: row[key] for key in ("name", "vcs", "hidden", "modified_at")}
                for row in local["items"]
            ],
        )
        remote_preview = remote["preview"]
        local_preview = local["preview"]
        for key in ("languages", "more"):
            self.assertEqual(remote_preview[key], local_preview[key])
        self.assertEqual(len(remote_preview["tree"]), len(local_preview["tree"]))
        for remote_row, local_row in zip(remote_preview["tree"], local_preview["tree"]):
            self.assertEqual(
                remote_row["location"], "fakehost:" + local_row["location"]
            )
            self.assertEqual(
                {
                    key: value
                    for key, value in remote_row.items()
                    if key not in {"location", "children"}
                },
                {
                    key: value
                    for key, value in local_row.items()
                    if key not in {"location", "children"}
                },
            )
            self.assertEqual(len(remote_row["children"]), len(local_row["children"]))
            for remote_child, local_child in zip(
                remote_row["children"], local_row["children"]
            ):
                self.assertEqual(
                    remote_child["location"], "fakehost:" + local_child["location"]
                )
                self.assertEqual(
                    {
                        key: value
                        for key, value in remote_child.items()
                        if key != "location"
                    },
                    {
                        key: value
                        for key, value in local_child.items()
                        if key != "location"
                    },
                )
        remote_repo = remote_preview["repository"]
        local_repo = local_preview["repository"]
        self.assertEqual(remote_repo is None, local_repo is None)
        if remote_repo is not None:
            self.assertEqual(remote_repo["root"], "fakehost:" + local_repo["root"])
            self.assertEqual(
                {key: value for key, value in remote_repo.items() if key != "root"},
                {key: value for key, value in local_repo.items() if key != "root"},
            )

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
        self.assertEqual(
            self.browse(f"fakehost:{tree}", preview=True)["preview"]["repository"][
                "kind"
            ],
            "git",
        )
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
        self.assertEqual(
            self.browse(f"fakehost:{tree}", preview=True)["preview"]["repository"][
                "kind"
            ],
            "jj",
        )
        self.assert_same_answers(tree)

    def test_a_remote_folder_answers_with_the_hosts_state(self):
        query = urllib.parse.urlencode({"location": "gone:/srv"})
        with self.assertRaises(urllib.error.HTTPError) as refused:
            self.app.api(f"/workspaces?{query}").close()
        self.assertEqual(refused.exception.code, 503)
        body = json.loads(refused.exception.read())
        self.assertEqual(body["status"], 503)
        self.assertIn("Connection refused", body["detail"])
        self.assertEqual(self.host("gone")["state"], "unreachable")
        # A session there still composes, its project files skipped.
        session = self.create("gone:/srv/app")["id"]
        with self.app.api(f"/sessions/{session}/catalog") as response:
            self.assertTrue(json.load(response)["discovery"]["candidates"])
        # A ~ path lists the remote home.
        listed = self.browse("fakehost:~")
        self.assertEqual(listed["directory"], f"fakehost:{self.remote_home}")
        self.assertIn("proj", [entry["name"] for entry in listed["items"]])

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
