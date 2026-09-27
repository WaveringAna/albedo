//// A kernel or its owner going away must still end every process the kernel
//// started, races beyond normal E2E teardown. Split from supervision_test so
//// the two run side by side.

import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/int
import gleeunit/should

/// Cells may not spawn processes themselves, but a library they call may:
/// this defines one, `spawn`, compiled outside any cell.
const library_spawn = "library = {}\nexec(compile('import subprocess\\ndef spawn(*args, **kwargs):\\n    return subprocess.Popen(*args, **kwargs)', 'fixture_library.py', 'exec'), library)\nspawn = library['spawn']\n"

pub fn owner_death_still_ends_reported_job_groups_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(started) =
    python.execute(
      kernel,
      "a",
      "late = run('sleep', '30', timeout=300)\nimport asyncio\nawait asyncio.sleep(0.3)\nlate.group.pgid",
      10_000,
    )
  let assert Ok(pgid) = int.parse(started.value)
  // Kill the kernel from inside a cell: no cleanup callback can run, so the
  // supervisor's own record of the job group is the only remaining owner.
  let assert Error(python.Lost) =
    python.execute(
      kernel,
      "b",
      "import os, signal\nos.kill(os.getpid(), signal.SIGKILL)",
      5000,
    )
  let assert Ok(probe) = python.local(store, "/tmp")
  let assert Ok(checked) =
    python.execute(
      probe,
      "c",
      "import os\nstate = 'alive'\ntry:\n    os.killpg("
        <> int.to_string(pgid)
        <> ", 0)\nexcept ProcessLookupError:\n    state = 'gone'\nstate",
      5000,
    )
  checked.value |> should.equal("'gone'")
  let assert Ok(_) = python.stop(probe)
  work.close(store)
}

pub fn kernel_death_ends_unregistered_children_in_its_own_group_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(started) =
    python.execute(kernel, "start", library_spawn <> "import subprocess
child = spawn(['sleep', '30'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
child.pid", 5000)
  let assert Ok(pid) = int.parse(started.value)
  let assert Error(python.Lost) =
    python.execute(
      kernel,
      "die",
      "import os, signal
os.kill(os.getpid(), signal.SIGKILL)",
      5000,
    )
  let assert Ok(probe) = python.local(store, "/tmp")
  let assert Ok(checked) = python.execute(probe, "check", "import os
state = 'alive'
try:
    os.kill(" <> int.to_string(pid) <> ", 0)
except ProcessLookupError:
    state = 'gone'
state", 5000)
  checked.value |> should.equal("'gone'")
  let assert Ok(_) = python.stop(probe)
  work.close(store)
}

pub fn shutdown_keeps_ownership_of_late_job_registrations_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(path) =
    python.execute(
      kernel,
      "start",
      library_spawn <> "import __main__ as kernel, os, subprocess, tempfile
from pathlib import Path
fd, report = tempfile.mkstemp(prefix='albedo-owned-shutdown-')
os.close(fd)
def late():
    child = spawn(['sleep', '30'], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    Path(report).write_text(str(child.pid))
    kernel.send({'type': 'job_start', 'id': 'late-fixture', 'pgid': child.pid})
    os._exit(0)
kernel.CLEANUP.append(late)
report",
      5000,
    )
  let assert Ok(_) = python.stop(kernel)
  let assert Ok(probe) = python.local(store, "/tmp")
  let assert Ok(checked) = python.execute(probe, "check", "import os
from pathlib import Path
report = Path(" <> path.value <> ")
pid = int(report.read_text())
report.unlink()
state = 'alive'
try:
    os.kill(pid, 0)
except ProcessLookupError:
    state = 'gone'
state", 5000)
  checked.value |> should.equal("'gone'")
  let assert Ok(_) = python.stop(probe)
  work.close(store)
}

pub fn owner_loss_terminates_a_kernel_held_in_native_code_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(started) =
    python.execute(
      kernel,
      "pid",
      "import os
os.getpid()",
      5000,
    )
  let assert Ok(pid) = int.parse(started.value)
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        python.execute(
          kernel,
          "native",
          "import ctypes
ctypes.PyDLL(None).sleep(30)",
          60_000,
        ),
      )
    })
  process.sleep(100)
  work.close(store)
  process.receive(reply, 8000) |> should.equal(Ok(Error(python.Lost)))
  let assert Ok(other) = work.start(":memory:")
  let assert Ok(probe) = python.local(other, "/tmp")
  let assert Ok(checked) = python.execute(probe, "check", "import os
state = 'alive'
try:
    os.kill(" <> int.to_string(pid) <> ", 0)
except ProcessLookupError:
    state = 'gone'
state", 5000)
  checked.value |> should.equal("'gone'")
  let assert Ok(_) = python.stop(probe)
  work.close(other)
}
