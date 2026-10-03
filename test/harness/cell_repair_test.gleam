//// Partially executed cells must not replay side effects without explicit permission.

import albedo/harness/extensions/python/cells
import albedo/harness/extensions/python/kernel as python
import albedo/harness/runtime
import gleam/string
import gleeunit/should
import harness/session_fixture

pub fn partial_execution_requires_explicit_replay_permission_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  session_fixture.initialise(host)
  session_fixture.create(host, "a", "/tmp")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(failed) =
    runtime.execute(
      host,
      session,
      "counter = globals().get('counter', 0) + 1\nraise ValueError('bad')",
      5000,
    )
  let assert Ok(original) = runtime.cell(host, failed.cell_id)
  original.started |> should.be_true
  let repair =
    "await cells.run('"
    <> failed.cell_id
    <> "', replacements=[(\"raise ValueError('bad')\", 'counter')]"
  let assert Ok(denied) = runtime.execute(host, session, repair <> ")", 5000)
  let assert Ok(denied) = denied.result
  denied.status |> should.equal(python.Failed)
  denied.output |> string.contains("allow_partial=True") |> should.be_true
  let assert Ok(counter) = runtime.execute(host, session, "counter", 5000)
  let assert Ok(counter) = counter.result
  counter.value |> should.equal("1")
  let assert Ok(allowed) =
    runtime.execute(host, session, repair <> ", allow_partial=True)", 5000)
  let assert Ok(allowed) = allowed.result
  allowed.value |> should.equal("2")
  runtime.stop(host)
}

pub fn ambiguous_repairs_and_compile_errors_do_not_execute_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  session_fixture.initialise(host)
  session_fixture.create(host, "a", "/tmp")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(failed) =
    runtime.execute(host, session, "state = 1\n(yield 1)", 5000)
  let assert Ok(original) = runtime.cell(host, failed.cell_id)
  original.started |> should.be_false
  let assert Ok(denied) =
    runtime.execute(
      host,
      session,
      "await cells.run('" <> original.id <> "', replacements=[('1', '2')])",
      5000,
    )
  let assert Ok(denied) = denied.result
  denied.status |> should.equal(python.Failed)
  denied.output |> string.contains("exactly once") |> should.be_true
  let assert Ok(state) =
    runtime.execute(host, session, "'state' in globals()", 5000)
  let assert Ok(state) = state.result
  state.value |> should.equal("False")
  runtime.stop(host)
}

pub fn reused_call_id_does_not_fail_unique_constraint_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  let storage = runtime.ledger(host)
  let session = "test-session"
  let assert Ok(first_id) =
    cells.begin_call(storage, session, "call_0", "x = 1")
  first_id |> should.equal(session <> "/call_0")

  let assert Ok(second_id) =
    cells.begin_call(storage, session, "call_0", "x = 2")
  string.starts_with(second_id, session <> "/call_0-") |> should.be_true
  { first_id != second_id } |> should.be_true

  let assert Ok(found) = cells.find_call(storage, session <> "/call_0")
  found.id |> should.equal(second_id)

  runtime.stop(host)
}
