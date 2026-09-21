import albedo/daemon/conversation
import albedo/harness/bash
import albedo/harness/compaction
import albedo/harness/plugin
import albedo/harness/plugins
import albedo/harness/python
import albedo/harness/python/kernel
import albedo/harness/runtime
import albedo/harness/work
import albedo/openai_api/types
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
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

pub fn work_is_a_python_tool_plugin_test() {
  let assert Ok(host) =
    runtime.start_with_plugins(":memory:", [python.plugin(), work.plugin()])
  let assert Ok(session) = runtime.open_session(host, "work-plugin", "/tmp")
  let assert Ok(execution) =
    runtime.execute(
      host,
      session,
      "item = await work.create('plugin work')\n(await work.get(item['id']))['title']",
      5000,
    )
  let assert Ok(result) = execution.result
  result.value |> should.equal("'plugin work'")
  runtime.tools(host)
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["python"])
  runtime.stop(host)
}

pub fn plugin_validation_happens_before_initialisers_test() {
  let called = process.new_subject()
  let first =
    plugin.Plugin(..python.plugin(), initialise: fn(_) {
      process.send(called, "initialised")
      Ok(Nil)
    })
  runtime.start_with_plugins(":memory:", [first, first]) |> should.be_error
  process.receive(called, 0) |> should.equal(Error(Nil))
  let repeated_tool =
    plugin.Plugin(..python.plugin(), tools: [
      plugin.Tool(python.definition(), python.invoke, fn(_) { None }),
      plugin.Tool(python.definition(), python.invoke, fn(_) { None }),
    ])
  runtime.start_with_plugins(":memory:", [repeated_tool]) |> should.be_error
  let nested_route =
    plugin.Plugin(..work.plugin(), routes: [
      #("work", fn(_, _, _) { "" }),
      #("work.private", fn(_, _, _) { "" }),
    ])
  runtime.start_with_plugins(":memory:", [python.plugin(), nested_route])
  |> should.be_error
  let repeated_module =
    plugin.Plugin(..bash.plugin(), python_modules: [
      "bash",
      "albedo_plugins.bash",
    ])
  runtime.start_with_plugins(":memory:", [python.plugin(), repeated_module])
  |> should.be_error
}

pub fn compaction_is_optional_and_has_one_request_view_owner_test() {
  let history = [types.User("one"), types.Assistant("two"), types.User("three")]
  let assert Ok(host) =
    runtime.start_with_plugins(":memory:", [python.plugin()])
  let assert Ok(session) = runtime.open_session(host, "unchanged", "/tmp")
  runtime.prepare_history(host, session, "fixture", history)
  |> should.equal(Ok(history))
  runtime.stop(host)
  // A test-only strategy proves the hook, not a shipped compaction policy.
  let strategy =
    compaction.Strategy("fixture", fn(context, inputs) {
      context.session |> should.equal("projected")
      context.model |> should.equal("fixture-model")
      inputs |> should.equal(history)
      Ok([types.User("request-only fixture")])
    })
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      plugins.Config([python.plugin()], Some(strategy)),
    )
  let assert Ok(session) = runtime.open_session(host, "projected", "/tmp")
  let assert Ok(_) = conversation.initialise(runtime.ledger(host))
  let info =
    conversation.Info(
      "projected",
      "title",
      "/tmp",
      "fixture",
      "fixture-model",
      types.Responses,
      "idle",
      None,
    )
  let assert Ok(_) = conversation.create(runtime.ledger(host), info)
  let assert Ok(_) =
    conversation.commit(runtime.ledger(host), "projected", history, "idle")
  runtime.prepare_history(host, session, "fixture-model", history)
  |> should.equal(Ok([types.User("request-only fixture")]))
  conversation.load(runtime.ledger(host), "projected")
  |> should.equal(Ok(history))
  runtime.stop(host)
}

pub fn compaction_failure_stops_request_preparation_test() {
  let strategy = compaction.Strategy("fixture", fn(_, _) { Error("not ready") })
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      plugins.Config([python.plugin()], Some(strategy)),
    )
  let assert Ok(session) = runtime.open_session(host, "failure", "/tmp")
  runtime.prepare_history(host, session, "fixture", [types.User("keep")])
  |> should.equal(Error("compaction fixture: not ready"))
  runtime.stop(host)
}

pub fn explicit_python_module_is_embedded_and_startup_errors_name_it_test() {
  let module =
    plugin.python_module(
      "shell",
      "albedo_plugins.bash",
      "Use bash from Python.",
    )
  let assert Ok(host) =
    runtime.start_with_plugins(":memory:", [python.plugin(), module])
  let assert Ok(session) = runtime.open_session(host, "module", "/tmp")
  let assert Ok(execution) =
    runtime.execute(
      host,
      session,
      "job = await bash('printf embedded')\njob.tail()",
      5000,
    )
  let assert Ok(result) = execution.result
  result.value |> should.equal("'embedded'")
  runtime.stop(host)
  let absent =
    plugin.python_module("missing", "albedo_missing_fixture.tools", "")
  let assert Ok(host) =
    runtime.start_with_plugins(":memory:", [python.plugin(), absent])
  let assert Error(kernel.Unavailable(error)) =
    runtime.open_session(host, "missing", "/tmp")
  error |> string.contains("albedo_missing_fixture.tools") |> should.be_true
  runtime.stop(host)
}
