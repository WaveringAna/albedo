//// Kernel ownership and timed-out execution state need nonflaky runtime-level probes.

import albedo/daemon/conversation
import albedo/daemon/session
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extension/selection
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/python/link
import albedo/harness/runtime
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import harness/session_fixture

@external(erlang, "albedo_runtime_test_support", "kernel_memory")
fn kernel_memory(session: runtime.Session) -> Int

@external(erlang, "albedo_runtime_test_support", "temporary_workspace")
fn temporary_workspace() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup_workspace")
fn cleanup_workspace(path: String) -> Nil

@external(erlang, "albedo_copy_test_support", "captured_words")
fn captured_words(term: a) -> Int

/// Every http request and every turn's worker copies the runtime handle and
/// a session's selection into a fresh process, so neither may carry the
/// installed extensions: the handle shares them, a selection points at them.
pub fn runtime_handle_and_selection_carry_no_installed_copy_test() -> Nil {
  let workspace = temporary_workspace()
  let assert Ok(host) = runtime.start(":memory:")
  session_fixture.initialise(host)
  session_fixture.create(host, "handle", workspace)
  let assert Ok(_) = runtime.open_session(host, "handle", workspace)
  let baseline = captured_words(Nil)
  let installed = runtime.installed(host)
  let assert Ok(enabled) = runtime.global(host)
  // Measured while the runtime lives: its stop releases the shared value,
  // which lands a copy on every heap still holding it.
  let handle_words = captured_words(host)
  let installed_words = captured_words(installed)
  let enabled_words = captured_words(enabled)
  runtime.stop(host)
  cleanup_workspace(workspace)
  should.be_true(list.length(installed) > 10)
  should.be_true(list.length(enabled) > 10)
  // The handle: a subject, a store, and a shared reference.
  should.be_true(handle_words < baseline + 256)
  installed_words |> should.equal(baseline)
  // A session's selection: one cons cell per enabled extension.
  should.be_true(enabled_words < baseline + 256)
}

pub fn kernel_host_ownership_does_not_grow_with_the_swarm_test() -> Nil {
  let workspace = temporary_workspace()
  let assert Ok(host) = runtime.start_with_extensions(":memory:", [])
  session_fixture.initialise(host)
  session_fixture.create(host, "first", workspace)
  let assert Ok(first) = runtime.open_session(host, "first", workspace)
  let baseline = kernel_memory(first)
  // A hundred dormant compositions, not a hundred OS processes. None belongs
  // in another kernel's RPC closure or in the worker that boots that kernel.
  list.repeat(Nil, 100)
  |> list.index_map(fn(_, n) {
    let id = "dormant-" <> int.to_string(n)
    session_fixture.create(host, id, workspace)
    let assert Ok(_) = runtime.peek_commands(host, id, workspace)
    let assert Ok(observed) = runtime.observe_loaded(host, id)
    observed.kernel |> should.equal(None)
    observed.phase |> should.equal("none")
  })
  session_fixture.create(host, "last", workspace)
  let assert Ok(last) = runtime.open_session(host, "last", workspace)
  let opened = kernel_memory(last)
  let assert Ok(Some(refreshed)) =
    runtime.reload_desired(host, "last", workspace)
  let rebound = kernel_memory(refreshed)
  runtime.stop(host)
  cleanup_workspace(workspace)
  // Allocator size classes may differ; sibling state must not accumulate.
  should.be_true(opened <= baseline * 2 + 4096)
  should.be_true(rebound <= baseline * 2 + 4096)
}

pub fn hard_timeout_requires_explicit_reset_test() -> Nil {
  let assert Ok(host) = runtime.start(":memory:")
  session_fixture.initialise(host)
  session_fixture.create(host, "a", "/tmp")
  let assert Ok(session) = runtime.open_session(host, "a", "/tmp")
  // SIGINT is ignored before the timed cell starts: in the same cell, a
  // deadline landing ahead of the signal.signal line under load is a
  // graceful interrupt instead.
  let assert Ok(_) =
    runtime.execute(
      host,
      session,
      "import signal\nsignal.signal(signal.SIGINT, signal.SIG_IGN)",
      10_000,
    )
  let assert Ok(execution) =
    runtime.execute(host, session, "while True: pass", 100)
  execution.result |> should.equal(Error(python.Lost))
  runtime.open_session(host, "a", "/tmp") |> should.equal(Error(python.Lost))
  runtime.reset_session(host, "a")
  let assert Ok(_) = runtime.open_session(host, "a", "/tmp")
  runtime.stop(host)
}

@external(erlang, "albedo_runtime_test_support", "catalog_does_not_block")
fn catalog_does_not_block(
  runtime: runtime.Runtime,
  home: String,
  id: String,
) -> #(Bool, Bool)

pub fn catalog_store_wait_does_not_block_runtime_observations_test() -> Nil {
  let home = temporary_workspace()
  let assert Ok(host) = runtime.start(":memory:")
  session_fixture.initialise(host)
  session_fixture.create(host, "catalog", home)
  let #(responsive, completed) = catalog_does_not_block(host, home, "catalog")
  runtime.stop(host)
  cleanup_workspace(home)
  responsive |> should.be_true
  completed |> should.be_true
}

@external(erlang, "albedo_runtime_test_support", "catalog_forget_while_blocked")
fn catalog_forget_while_blocked(
  runtime: runtime.Runtime,
  home: String,
  id: String,
) -> Result(runtime.CatalogObservation, String)

pub fn stale_catalog_retries_against_current_composition_test() -> Nil {
  let home = temporary_workspace()
  let assert Ok(host) = runtime.start_with_extensions(":memory:", [])
  session_fixture.initialise(host)
  session_fixture.create(host, "catalog", home)
  let assert Ok(_) = runtime.peek_commands(host, "catalog", home)
  let assert Ok(initial) = runtime.observe_catalog(host, home, "catalog")
  should.be_true(initial.loaded_revision != None)
  let assert Ok(current) = catalog_forget_while_blocked(host, home, "catalog")
  current.loaded_revision |> should.equal(None)
  runtime.loaded_sessions(host) |> should.equal([])
  let assert Ok(fresh) = runtime.observe_catalog(host, home, "catalog")
  fresh.loaded_revision |> should.equal(None)
  runtime.stop(host)
  cleanup_workspace(home)
}

@external(erlang, "albedo_runtime_test_support", "hold_preparation")
fn hold_preparation(
  parent: process.Pid,
  workspace: String,
) -> Result(String, String)

@external(erlang, "albedo_runtime_test_support", "capture_during_preparation")
fn capture_during_preparation(
  host: runtime.Runtime,
  reader: session.Session,
  requests: List(#(String, String)),
) -> #(Result(session.Capture, String), Bool)

pub fn blocked_preparations_leave_session_capture_responsive_test() -> Nil {
  let home = temporary_workspace()
  let parent = process.self()
  let held =
    extension.Extension(
      name: "held-context",
      description: "context loading controlled by the test's release barrier",
      requires: [],
      plugins: [
        extension.ContextPlugin(fn(workspace) {
          hold_preparation(parent, workspace)
        }),
      ],
      initialise: fn(ledger) { store.query(ledger, link.apply) },
    )
  let assert Ok(host) = runtime.start_with_extensions(":memory:", [held])
  session_fixture.initialise(host)
  let requests =
    list.repeat(Nil, 8)
    |> list.index_map(fn(_, index) {
      let id = "preparing-" <> int.to_string(index)
      let workspace = temporary_workspace()
      session_fixture.create(host, id, workspace)
      // Keep the blocking loader selected regardless of shared global defaults.
      let assert Ok(_) =
        selection.record_selected(
          runtime.ledger(host),
          id,
          selection.SetSession(held.name, True),
          [],
          [held],
          [held],
        )
      #(id, workspace)
    })
  session_fixture.create(host, "reader", home)
  let assert Ok(info) = conversation.get(runtime.ledger(host), "reader")
  let assert Ok(reader) = session.start(host, info, home)
  let #(outcome, completed) = capture_during_preparation(host, reader, requests)
  session.close(reader)
  runtime.stop(host)
  list.each(requests, fn(request) { cleanup_workspace(request.1) })
  cleanup_workspace(home)
  let assert Ok(captured) = outcome
  captured.info.id |> should.equal("reader")
  completed |> should.be_true
}
