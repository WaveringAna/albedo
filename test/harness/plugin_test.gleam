import albedo/harness/bash
import albedo/harness/python
import albedo/harness/runtime
import gleeunit/should

pub fn python_alone_has_no_bash_or_work_test() {
  let assert Ok(host) =
    runtime.start_with_plugins(":memory:", [python.plugin()])
  let assert Ok(session) = runtime.open_session(host, "isolated", "/tmp")
  let assert Ok(execution) =
    runtime.execute(
      host,
      session,
      "('bash' in globals(), 'work' in globals(), 'cells' in globals())",
      1000,
    )
  let assert Ok(result) = execution.result
  result.value |> should.equal("(False, False, True)")
  runtime.stop(host)
}

pub fn dependency_order_is_explicit_test() {
  runtime.start_with_plugins(":memory:", [bash.plugin(), python.plugin()])
  |> should.be_error
}
