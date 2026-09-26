//// Kernel-level supervision: owned process groups, quota accounting, verified stops.

import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/int
import gleeunit/should

/// A group and the descendant that outlived the command must become
/// absent. Permission errors do not prove termination.
const reaped_probe = "import os, time\nstate = 'alive'\nfor _ in range(50):\n"
  <> "    reachable = 0\n"
  <> "    for probe in (lambda: os.killpg(job.group.pgid, 0), lambda: os.kill(grandchild, 0)):\n"
  <> "        try:\n            probe()\n            reachable += 1\n"
  <> "        except ProcessLookupError:\n            pass\n"
  <> "    if reachable == 0:\n        state = 'gone'\n        break\n"
  <> "    time.sleep(0.02)\n"

/// Parent programs for a job, as `program`: each prints the pid of a sleeping
/// child that stays in the job's group, then waits for it or leaves it behind.
const waits_on_a_sleeper = "program = 'import subprocess; child = subprocess.Popen([\"sleep\", \"30\"]); print(child.pid, flush=True); child.wait()'\n"

/// Cells may not spawn processes themselves, but a library they call may:
/// this defines one, `spawn`, compiled outside any cell.
const library_spawn = "library = {}\nexec(compile('import subprocess\\ndef spawn(*args, **kwargs):\\n    return subprocess.Popen(*args, **kwargs)', 'fixture_library.py', 'exec'), library)\nspawn = library['spawn']\n"

const leaves_a_sleeper = "program = 'import subprocess; child = subprocess.Popen([\"sleep\", \"30\"]); print(child.pid, flush=True)'\n"

pub fn completed_jobs_do_not_consume_the_running_quota_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(first) =
    python.execute(
      kernel,
      "a",
      "job = run('printf', 'first')\nawait job\n(job.poll(), job.tail())",
      5000,
    )
  first.value |> should.equal("(0, 'first')")
  let assert Ok(many) =
    python.execute(
      kernel,
      "b",
      "for _ in range(70):\n    await run('true')\n(len(jobs), job.poll(), job.tail())",
      60_000,
    )
  many.status |> should.equal(python.Succeeded)
  // 70 finished jobs start, the addressable index stays bounded, and the oldest
  // handle still answers although newer completions displaced it from `jobs`.
  many.value |> should.equal("(64, 0, 'first')")
  let assert Ok(_) = python.stop(kernel)
  work.close(store)
}

pub fn deadline_ends_the_group_and_reports_it_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(outcome) =
    python.execute(
      kernel,
      "a",
      waits_on_a_sleeper
        <> "import os, sys\njob = run(sys.executable, '-c', program, timeout=0.1)\nawait job\n"
        <> "grandchild = int(job.tail().split()[0])\n"
        <> reaped_probe
        <> "(job.timed_out, job.termination.gone, state, job.poll() < 0, "
        <> "'deadline exceeded after 0.1s' in job.tail(), 'terminated' in job.tail())",
      10_000,
    )
  outcome.status |> should.equal(python.Succeeded)
  outcome.value |> should.equal("(True, True, 'gone', True, True, True)")
  let assert Ok(_) = python.stop(kernel)
  work.close(store)
}

pub fn command_exit_ends_a_descendant_that_holds_output_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(outcome) =
    python.execute(
      kernel,
      "a",
      leaves_a_sleeper
        <> "import os, sys, time\nstarted = time.monotonic()\n"
        <> "job = run(sys.executable, '-c', program, timeout=30)\nawait job\n"
        <> "grandchild = int(job.tail().split()[0])\n"
        <> reaped_probe
        <> "(job.timed_out, job.termination.gone, state, time.monotonic() - started < 5)",
      10_000,
    )
  outcome.status |> should.equal(python.Succeeded)
  outcome.value |> should.equal("(False, True, 'gone', True)")
  let assert Ok(_) = python.stop(kernel)
  work.close(store)
}

pub fn stop_ends_a_running_job_group_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(started) =
    python.execute(
      kernel,
      "a",
      "import asyncio\nlate = run('sleep', '30', timeout=300)\nawait asyncio.sleep(0.3)\nlate.group.pgid",
      10_000,
    )
  let assert Ok(pgid) = int.parse(started.value)
  // The typed stop is the supervisor's verdict: every owned group is gone.
  let assert Ok(_) = python.stop(kernel)
  let assert Ok(probe) = python.local(store, "/tmp")
  let assert Ok(checked) =
    python.execute(
      probe,
      "b",
      "import os\nstate = 'alive'\ntry:\n    os.killpg("
        <> int.to_string(pgid)
        <> ", 0)\nexcept ProcessLookupError:\n    state = 'gone'\nstate",
      5000,
    )
  checked.value |> should.equal("'gone'")
  let assert Ok(_) = python.stop(probe)
  work.close(store)
}

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
