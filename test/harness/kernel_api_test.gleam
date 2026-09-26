//// The model-facing Python API in a live kernel, where a fake cannot hide drift.

import albedo/harness/extensions/files/extension as files
import albedo/harness/extensions/python/extension as python
import albedo/harness/extensions/run/extension as run
import albedo/harness/extensions/work/extension as work
import albedo/harness/runtime
import gleeunit/should

pub fn a_search_leaves_no_job_or_output_channel_test() {
  let assert Ok(host) =
    runtime.start_with_extensions(":memory:", [
      python.extension(),
      run.extension(),
      files.extension(),
    ])
  let assert Ok(session) = runtime.open_session(host, "search", "/tmp")
  let assert Ok(execution) =
    runtime.execute(
      host,
      session,
      "import os, tempfile\n"
        <> "root = tempfile.mkdtemp()\n"
        <> "open(os.path.join(root, 'a.txt'), 'w').write('needle\\n')\n"
        <> "found = await files.find('needle', root)\n"
        <> "named = await files.paths('a.txt', root)\n"
        <> "(len(found), len(named), len(jobs), [c['kind'] for c in output.list() if c['kind'] == 'job'])",
      30_000,
    )
  let assert Ok(outcome) = execution.result
  outcome.value |> should.equal("(1, 1, 0, [])")
  runtime.stop(host)
}

// Cells are listable after their output rolls out, report a status, and the
// ledger answers records; synchronous output calls may also be awaited.
pub fn cells_records_and_awaitable_output_test() {
  let assert Ok(host) =
    runtime.start_with_extensions(":memory:", [
      python.extension(),
      work.extension(),
    ])
  let assert Ok(session) = runtime.open_session(host, "api", "/tmp")
  let assert Ok(_) = runtime.execute(host, session, "1 / 0", 5000)
  let assert Ok(execution) =
    runtime.execute(
      host,
      session,
      "cells_now = await cells.list()\n"
        <> "failed = await cells.info(cells_now[1].id)\n"
        <> "item = await work.create('probe', 'from a test')\n"
        <> "listing = await output.list()\n"
        <> "(len(cells_now), cells_now[1].first_line, failed.status, item.title == item['title'], "
        <> "type(listing).__name__, await work.delete(item.id, revision=item.revision) == item)",
      10_000,
    )
  let assert Ok(outcome) = execution.result
  outcome.value
  |> should.equal("(2, '1 / 0', 'error', True, 'ReadyList', True)")
  runtime.stop(host)
}
