//// Process-group termination must clean up descendants and races beyond normal E2E teardown.
//// Kernel-level supervision: owned process groups, quota accounting, verified stops.

import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
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

const leaves_a_sleeper = "program = 'import subprocess; child = subprocess.Popen([\"sleep\", \"30\"]); print(child.pid, flush=True)'\n"

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
