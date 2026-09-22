import albedo/harness/extensions/python/kernel as python
import albedo/harness/runtime
import gleam/option.{Some}
import gleam/string
import gleeunit/should

pub fn syntax_failure_can_be_repaired_without_resending_payload_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let source =
    "payload = '" <> string.repeat("x", 100_000) <> "'\nanswer = 1 +\nanswer"
  let assert Ok(failed) = runtime.execute(host, session, source, 5000)
  let assert Ok(outcome) = failed.result
  outcome.status |> should.equal(python.Failed)
  let assert Ok(original) = runtime.cell(host, failed.cell_id)
  original.started |> should.be_false
  original.source |> should.equal(source)
  let assert Ok(check) =
    runtime.execute(host, session, "'payload' in globals()", 5000)
  let assert Ok(outcome) = check.result
  outcome.value |> should.equal("False")
  let repair =
    "await cells.run('"
    <> failed.cell_id
    <> "', replacements=[('answer = 1 +', 'answer = 1 + 2')])"
  let assert Ok(repaired) = runtime.execute(host, session, repair, 5000)
  let assert Ok(outcome) = repaired.result
  outcome.status |> should.equal(python.Succeeded)
  outcome.value |> should.equal("3")
  let assert Ok(last) =
    runtime.execute(host, session, "print(cells.last_id)", 5000)
  let assert Ok(last) = last.result
  let assert Ok(copy) = runtime.cell(host, string.trim(last.output))
  copy.parent |> should.equal(Some(original.id))
  copy.started |> should.be_true
  let assert Ok(unchanged) = runtime.cell(host, original.id)
  unchanged |> should.equal(original)
  runtime.reset_session(host, "a")
  let assert Ok(fresh) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(read) =
    runtime.execute(
      host,
      fresh,
      "await cells.read('" <> original.id <> "', start_line=2, end_line=2)",
      5000,
    )
  let assert Ok(read) = read.result
  read.value |> should.equal("'answer = 1 +\\n'")
  let assert Ok(capped) =
    runtime.execute(
      host,
      fresh,
      "text = await cells.read('"
        <> original.id
        <> "', limit=64)\n(len(text) < 200, text.endswith('raise limit]'))",
      5000,
    )
  let assert Ok(capped) = capped.result
  capped.value |> should.equal("(True, True)")
  runtime.stop(host)
}

pub fn a_checked_repair_compiles_without_saving_or_running_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(failed) =
    runtime.execute(host, session, "marker = 1\nvalue = 1 +\nvalue", 5000)
  let repair = "await cells.run('" <> failed.cell_id <> "', replacements="
  let assert Ok(rejected) =
    runtime.execute(
      host,
      session,
      "print(" <> repair <> "[('1 +', '1 + +')], check=True))",
      5000,
    )
  let assert Ok(rejected) = rejected.result
  rejected.status |> should.equal(python.Succeeded)
  rejected.output |> string.contains("SyntaxError") |> should.be_true
  let assert Ok(accepted) =
    runtime.execute(
      host,
      session,
      "("
        <> repair
        <> "[('value = 1 +', 'value = 1 + 2')], check=True), cells.last_id, 'marker' in globals())",
      5000,
    )
  let assert Ok(accepted) = accepted.result
  accepted.value |> should.equal("(None, None, False)")
  let assert Ok(repaired) =
    runtime.execute(
      host,
      session,
      repair <> "[('value = 1 +', 'value = 1 + 2')])",
      5000,
    )
  let assert Ok(repaired) = repaired.result
  repaired.value |> should.equal("3")
  runtime.stop(host)
}

pub fn partial_execution_requires_explicit_replay_permission_test() {
  let assert Ok(host) = runtime.start(":memory:")
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

pub fn ambiguous_repairs_and_compile_errors_do_not_execute_test() {
  let assert Ok(host) = runtime.start(":memory:")
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
