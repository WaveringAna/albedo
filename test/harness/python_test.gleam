import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import gleam/erlang/process
import gleam/string
import gleeunit/should

/// Every stop must end the kernel's process groups; a survivor fails the test.
fn stop(kernel: python.Kernel) -> Nil {
  let assert Ok(_) = python.stop(kernel)
  Nil
}

pub fn persistent_namespace_and_shared_ledger_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(first) =
    python.execute(
      kernel,
      "a",
      "x = 40\nitem = await work.create('fix cancellation')\nprint(item['title'])\nx + 2",
      5000,
    )
  first.status |> should.equal(python.Succeeded)
  first.output |> should.equal("fix cancellation\n")
  first.value |> should.equal("42")
  let assert Ok([item]) = work.list(store, 0, 10)
  let assert Ok(_) = work.update(store, work.Item(..item, status: work.Done))
  let assert Ok(second) =
    python.execute(
      kernel,
      "b",
      "(x, (await work.get(item['id']))['status'])",
      5000,
    )
  second.value |> should.equal("(40, 'done')")
  let assert Ok(conflict) =
    python.execute(
      kernel,
      "c",
      "await work.update(item['id'], revision=item['revision'], status='active')",
      5000,
    )
  conflict.status |> should.equal(python.Failed)
  conflict.output |> string.contains("WorkError") |> should.be_true
  stop(kernel)
  work.close(store)
}

pub fn background_progress_and_timeout_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(_) =
    python.execute(
      kernel,
      "a",
      "import asyncio\nflag = False\nasync def later():\n    global flag\n    await asyncio.sleep(0.02)\n    flag = True\ntask = asyncio.create_task(later())",
      5000,
    )
  process.sleep(100)
  let assert Ok(flag) = python.execute(kernel, "b", "flag", 5000)
  flag.value |> should.equal("True")
  let assert Ok(timed) =
    python.execute(kernel, "c", "await asyncio.sleep(30)", 50)
  timed.status |> should.equal(python.Interrupted)
  timed.output |> string.contains("cell deadline exceeded") |> should.be_true
  let assert Ok(next) = python.execute(kernel, "d", "flag", 5000)
  next.value |> should.equal("True")
  stop(kernel)
  work.close(store)
}

pub fn errors_do_not_rollback_and_output_is_bounded_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(_) =
    python.execute(kernel, "a", "x = 5\nraise ValueError('failure')", 5000)
  let assert Ok(out) =
    python.execute(kernel, "b", "print('a' * 100000)\nx", 5000)
  out.value |> should.equal("5")
  out.truncated |> should.be_true
  string.byte_size(out.output) |> should.equal(65_536)
  let assert Ok(saved) =
    python.execute(
      kernel,
      "c",
      "len(output.read('b', offset=65536, limit=40000))",
      5000,
    )
  saved.value |> should.equal("34465")
  stop(kernel)
  work.close(store)
}

pub fn shell_handles_and_job_output_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(first) =
    python.execute(kernel, "a", "job = bash('printf hello; exit 3')\njob", 5000)
  first.value |> string.contains("Job(") |> should.be_true
  let assert Ok(second) =
    python.execute(kernel, "b", "await job\n(job.poll(), job.tail())", 5000)
  second.value |> should.equal("(3, 'hello')")
  python.events(kernel) |> should.not_equal([])
  // A job's output is addressable by id, and an id nobody retained says where to look.
  let assert Ok(archived) =
    python.execute(kernel, "c", "output.read(job.id)", 5000)
  archived.value |> should.equal("'hello'")
  let assert Ok(missing) =
    python.execute(
      kernel,
      "d",
      "try:\n    output.read('0')\nexcept LookupError as error:\n    print(error)",
      5000,
    )
  missing.output |> string.contains("jobs['0'].tail()") |> should.be_true
  stop(kernel)
  work.close(store)
}

/// A subprocess writing to the inherited fd keeps its place among the cell's prints.
pub fn native_output_joins_the_running_cell_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(ordered) =
    python.execute(
      kernel,
      "a",
      "import subprocess\nprint('A')\nsubprocess.run(['sh', '-c', 'printf B'])\nprint('C')",
      5000,
    )
  ordered.output |> should.equal("A\nBC\n")
  let assert Ok(_) =
    python.execute(
      kernel,
      "b",
      "late = subprocess.Popen(['sh', '-c', 'sleep 0.2; printf late'])",
      5000,
    )
  process.sleep(600)
  let assert Ok(native) =
    python.execute(kernel, "c", "output.read('native')", 5000)
  native.value |> should.equal("'late'")
  stop(kernel)
  work.close(store)
}

pub fn busy_and_explicit_interrupt_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        reply,
        python.execute(
          kernel,
          "a",
          "import asyncio\nawait asyncio.sleep(30)",
          5000,
        ),
      )
    })
  process.sleep(100)
  python.execute(kernel, "b", "42", 5000) |> should.equal(Error(python.Busy))
  python.interrupt(kernel)
  let assert Ok(Ok(interrupted)) = process.receive(reply, 3000)
  interrupted.status |> should.equal(python.Interrupted)
  let assert Ok(next) = python.execute(kernel, "c", "42", 5000)
  next.value |> should.equal("42")
  stop(kernel)
  work.close(store)
}

pub fn errors_remain_visible_after_output_flood_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(out) =
    python.execute(
      kernel,
      "a",
      "print('x' * 200000)\nraise ValueError('visible error')",
      5000,
    )
  out.status |> should.equal(python.Failed)
  out.output |> string.contains("visible error") |> should.be_true
  out.truncated |> should.be_true
  stop(kernel)
  work.close(store)
}

pub fn imports_follow_the_current_workspace_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(out) =
    python.execute(
      kernel,
      "a",
      "import os, tempfile\nfrom pathlib import Path\nwith tempfile.TemporaryDirectory() as directory:\n    os.chdir(directory)\n    Path('albedo_local_module.py').write_text('answer = 42')\n    import albedo_local_module\n    print(albedo_local_module.answer)\nos.chdir('/tmp')",
      5000,
    )
  out.status |> should.equal(python.Succeeded)
  out.output |> should.equal("42\n")
  stop(kernel)
  work.close(store)
}

pub fn shell_deadline_is_reported_and_kernel_remains_usable_test() {
  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let assert Ok(outcome) =
    python.execute(
      kernel,
      "deadline",
      "job = bash('sleep 30', timeout=0.05)\nawait job\nprint(job.tail())\n(job.timed_out, job.exit_code < 0)",
      5000,
    )
  outcome.status |> should.equal(python.Succeeded)
  outcome.value |> should.equal("(True, True)")
  outcome.output
  |> string.contains("deadline exceeded after 0.05s")
  |> should.be_true
  let assert Ok(next) =
    python.execute(
      kernel,
      "next",
      "quick = await bash('printf done')\n(quick.timed_out, quick.tail())",
      5000,
    )
  next.value |> should.equal("(False, 'done')")
  stop(kernel)
  work.close(store)
}
