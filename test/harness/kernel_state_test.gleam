//// Variables outlive their kernel when they can be written to disk.

import albedo/harness/python/kernel as python
import albedo/harness/runtime
import gleam/list
import gleam/string
import gleeunit/should

fn temporary() -> String {
  "/tmp/albedo-state-" <> new_id() <> ".state"
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

pub fn saved_variables_return_to_a_fresh_kernel_test() {
  let path = temporary()
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(_) =
    runtime.execute(
      host,
      session,
      // The module goes out of scope again: what a name pickles to depends on
      // the engine, and this test must hold with or without dill installed.
      "import os\nos.chdir('/tmp')\ndel os\nanswer = 42\nrows = {'a': [1, 2, 3]}\nhandle = open('/dev/null')",
      5000,
    )
  let assert Ok(saved) = runtime.save_state(session, path, 30_000)
  saved.names |> should.equal(["answer", "rows"])
  // One value nobody can serialise costs only itself, and says why.
  let assert [#("handle", reason)] = saved.missed
  reason |> string.contains("TextIOWrapper") |> should.be_true

  runtime.reset_session(host, "a")
  let assert Ok(fresh) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(revived) = runtime.load_state(fresh, path, 30_000)
  revived.names |> should.equal(["answer", "rows"])
  revived.missed |> should.equal([])
  let assert Ok(after) =
    runtime.execute(
      host,
      fresh,
      "import os\n(answer, rows['a'], os.getcwd())",
      5000,
    )
  let assert Ok(after) = after.result
  after.value |> should.equal("(42, [1, 2, 3], '/private/tmp')")
  runtime.stop(host)
}

pub fn a_missing_state_file_is_reported_not_fatal_test() {
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Error(python.Invalid(message)) =
    runtime.load_state(session, temporary(), 5000)
  message |> string.contains("no saved state") |> should.be_true
  let assert Ok(alive) = runtime.execute(host, session, "1 + 1", 5000)
  let assert Ok(alive) = alive.result
  alive.value |> should.equal("2")
  runtime.stop(host)
}

pub fn session_objects_are_never_saved_test() {
  let path = temporary()
  let assert Ok(host) = runtime.start(":memory:")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(_) = runtime.execute(host, session, "kept = 1", 5000)
  let assert Ok(saved) = runtime.save_state(session, path, 30_000)
  list.contains(saved.names, "cells") |> should.be_false
  list.contains(saved.names, "bash") |> should.be_false
  list.contains(saved.names, "jobs") |> should.be_false
  saved.names |> should.equal(["kept"])
  runtime.stop(host)
}
