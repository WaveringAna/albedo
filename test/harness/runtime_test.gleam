//// Kernel ownership and timed-out execution state need nonflaky runtime-level probes.

import albedo/harness/extensions/python/kernel as python
import albedo/harness/runtime
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "kernel_memory")
fn kernel_memory(session: runtime.Session) -> Int

pub fn kernel_host_ownership_does_not_grow_with_the_swarm_test() {
  let assert Ok(host) = runtime.start_with_extensions(":memory:", [])
  let assert Ok(first) = runtime.open_session(host, "first", "/tmp")
  let baseline = kernel_memory(first)
  // A hundred dormant compositions, not a hundred OS processes. None belongs
  // in another kernel's RPC closure or in the worker that boots that kernel.
  list.repeat(Nil, 100)
  |> list.index_map(fn(_, n) {
    let assert Ok(_) =
      runtime.peek_commands(host, "dormant-" <> int.to_string(n), "/tmp")
  })
  let assert Ok(last) = runtime.open_session(host, "last", "/tmp")
  let opened = kernel_memory(last)
  let assert Ok(Some(refreshed)) = runtime.refresh_session(host, "last")
  let rebound = kernel_memory(refreshed)
  runtime.stop(host)
  // Allocator size classes may differ; sibling state must not accumulate.
  should.be_true(opened <= baseline * 2 + 4096)
  should.be_true(rebound <= baseline * 2 + 4096)
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
