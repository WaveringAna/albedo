import albedo/harness/extensions/python/cells as journal
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process
import gleam/option.{None, Some}
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

pub fn durable_work_and_native_cell_results_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let assert Ok(session) = runtime.open_session(host, "session", "/tmp")
  let assert Ok(item) =
    work.create(runtime.ledger(host), "survive restart", "notes", None)
  let assert Ok(execution) = runtime.execute(host, session, "x = 42\nx", 5000)
  let assert Ok(cell) = runtime.cell(host, execution.cell_id)
  cell.outcome |> should.equal(Some(execution.result))
  let assert Ok(pending) =
    journal.begin(runtime.ledger(host), "session", "dangerous()")
  runtime.stop(host)
  let assert Ok(restarted) = runtime.start(path)
  work.get(runtime.ledger(restarted), item.id) |> should.equal(Ok(item))
  runtime.cell(restarted, execution.cell_id) |> should.equal(Ok(cell))
  let assert Ok(uncertain) = runtime.cell(restarted, pending)
  uncertain.outcome |> should.equal(None)
  let assert Ok(fresh) = runtime.open_session(restarted, "session", "/tmp")
  let assert Ok(result) =
    runtime.execute(restarted, fresh, "'x' in globals()", 5000)
  let assert Ok(outcome) = result.result
  outcome.value |> should.equal("False")
  runtime.stop(restarted)
  cleanup(path)
}

pub fn sessions_outlive_callers_and_tools_share_the_runtime_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
      let assert Ok(_) = runtime.execute(host, session, "x = 9", 5000)
      process.send(reply, session)
    })
  let assert Ok(session) = process.receive(reply, 5000)
  let assert Ok(again) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(retained) = runtime.execute(host, again, "x", 5000)
  let assert Ok(retained) = retained.result
  retained.value |> should.equal("9")
  let call =
    types.ToolCall(
      "call",
      "python",
      "{\"code\":\"await work.create('from tool')\",\"timeout_ms\":5000}",
    )
  let assert Ok(types.ToolOutput("call", _)) =
    runtime.invoke(host, session, call)
  let assert Ok([item]) = work.list(runtime.ledger(host), 0, 50)
  item.title |> should.equal("from tool")
  let assert Ok(other) = runtime.open_session(host, "b", "/tmp")
  let assert Ok(execution) =
    runtime.execute(host, other, "'x' in globals()", 5000)
  let assert Ok(outcome) = execution.result
  outcome.value |> should.equal("False")
  runtime.reset_session(host, "a")
  let assert Ok(new) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(execution) =
    runtime.execute(host, new, "'x' in globals()", 5000)
  let assert Ok(outcome) = execution.result
  outcome.value |> should.equal("False")
  runtime.stop(host)
}

pub fn hard_timeout_requires_explicit_reset_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(execution) =
    runtime.execute(
      host,
      session,
      "import signal\nsignal.signal(signal.SIGINT, signal.SIG_IGN)\nwhile True: pass",
      100,
    )
  execution.result |> should.equal(Error(python.Lost))
  runtime.open_session(host, "a", "/tmp") |> should.equal(Error(python.Lost))
  runtime.reset_session(host, "a")
  let assert Ok(_) = runtime.open_session(host, "a", "/tmp")
  runtime.stop(host)
}
