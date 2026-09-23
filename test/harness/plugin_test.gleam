import albedo/daemon/conversation
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/python/extension as python
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn no_op(_) {
  Ok(Nil)
}

fn fixture_tool(name: String) -> extension.Tool {
  extension.Tool(
    types.Tool(
      name,
      "fixture",
      json.object([#("type", json.string("object"))]),
      True,
    ),
    fn(_, _) { Ok("fixture") },
    fn(_) { None },
  )
}

fn bundle(load) -> extension.Extension {
  extension.Extension(
    "bundle",
    "fixture mixed extension",
    ["python"],
    [
      extension.ContextPlugin(load),
      extension.ToolPlugin(
        "bundle instructions",
        [fixture_tool("fixture_tool")],
        ["bash"],
        [],
      ),
    ],
    no_op,
  )
}

pub fn context_loads_once_and_is_prefixed_after_compaction_test() {
  let loaded = process.new_subject()
  let context = fn(workspace) {
    process.send(loaded, workspace)
    Ok("fixture context")
  }
  let strategy =
    compaction.Strategy("fixture", fn(_, _) {
      Ok([types.User("compacted conversation")])
    })
  let compact =
    extension.Extension(
      "compact",
      "fixture compactor",
      [],
      [extension.CompactionPlugin(strategy)],
      no_op,
    )
  let installed = [python.extension(), bundle(context), compact]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, ["python", "bundle", "compact"]),
    )
  let assert Ok(session) = runtime.open_session(host, "context", "/tmp")
  process.receive(loaded, 0) |> should.equal(Ok("/tmp"))
  let history = [types.User("durable")]
  let assert Ok([types.User(prefix), types.User("compacted conversation")]) =
    runtime.prepare_history(host, session, "fixture", history)
  string.contains(prefix, "fixture context") |> should.be_true
  let assert Ok(_) = runtime.prepare_history(host, session, "fixture", history)
  process.receive(loaded, 0) |> should.equal(Error(Nil))
  runtime.stop(host)
}

pub fn reload_disables_every_bundle_contribution_and_persists_test() {
  let path = temporary_database()
  let installed = [python.extension(), bundle(fn(_) { Ok("bundle context") })]
  let config = extensions.Config(installed, ["python", "bundle"])
  let assert Ok(host) = runtime.start_with_config(path, config)
  let assert Ok(session) = runtime.open_session(host, "toggle", "/tmp")
  runtime.tools(session)
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["python", "fixture_tool"])
  let assert Ok(execution) =
    runtime.execute(host, session, "'bash' in globals()", 1000)
  let assert Ok(outcome) = execution.result
  outcome.value |> should.equal("True")
  let assert Ok(reloaded) =
    runtime.reload_extension(host, "toggle", "/tmp", "bundle", False)
  runtime.tools(reloaded)
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["python"])
  string.contains(runtime.instructions(reloaded), "bundle instructions")
  |> should.be_false
  runtime.prepare_history(host, reloaded, "fixture", [
    types.User("conversation"),
  ])
  |> should.equal(Ok([types.User("conversation")]))
  let assert Ok(execution) =
    runtime.execute(host, reloaded, "'bash' in globals()", 1000)
  let assert Ok(outcome) = execution.result
  outcome.value |> should.equal("False")
  runtime.stop(host)

  let assert Ok(restarted) = runtime.start_with_config(path, config)
  let assert Ok([_, summary]) = runtime.extension_summaries(restarted, "toggle")
  summary.name |> should.equal("bundle")
  summary.enabled |> should.be_false
  let assert Ok(reopened) = runtime.open_session(restarted, "toggle", "/tmp")
  runtime.tools(reopened)
  |> list.map(fn(tool) { tool.name })
  |> should.equal(["python"])
  runtime.stop(restarted)
  cleanup(path)
}

pub fn dependencies_and_reload_readiness_guard_selection_test() {
  let dependent = bundle(fn(_) { Ok("") })
  let broken =
    extension.python_module(
      "broken",
      "missing module fixture",
      "albedo_missing_fixture.tools",
      "",
      ["python"],
    )
  let installed = [python.extension(), dependent, broken]
  let config = extensions.Config(installed, ["python", "bundle"])
  let assert Ok(host) = runtime.start_with_config(":memory:", config)
  let assert Ok(_) = runtime.open_session(host, "guard", "/tmp")
  runtime.reload_extension(host, "guard", "/tmp", "python", False)
  |> should.equal(Error("bundle requires enabled extension python"))
  let assert Error(error) =
    runtime.reload_extension(host, "guard", "/tmp", "broken", True)
  string.contains(error, "could not reload extensions") |> should.be_true
  let assert Ok(summaries) = runtime.extension_summaries(host, "guard")
  let assert Ok(broken) =
    list.find(summaries, fn(item) { item.name == "broken" })
  broken.enabled |> should.be_false
  runtime.stop(host)
}

pub fn registry_supports_disabled_compaction_alternatives_test() {
  let one =
    extension.Extension(
      "one",
      "first strategy",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("one", fn(_, value) { Ok(value) }),
        ),
      ],
      no_op,
    )
  let two =
    extension.Extension(
      "two",
      "second strategy",
      [],
      [
        extension.CompactionPlugin(
          compaction.Strategy("two", fn(_, value) { Ok(value) }),
        ),
      ],
      no_op,
    )
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config([python.extension(), one, two], ["python", "one"]),
    )
  let assert Ok(_) = runtime.open_session(host, "compact", "/tmp")
  let assert Error(error) =
    runtime.reload_extension(host, "compact", "/tmp", "two", True)
  string.contains(error, "multiple compaction") |> should.be_true
  runtime.stop(host)
}

pub fn transcript_remains_durable_when_context_is_request_only_test() {
  let assert Ok(host) =
    runtime.start_with_extensions(":memory:", [
      python.extension(),
      bundle(fn(_) { Ok("ephemeral") }),
    ])
  let assert Ok(_) = conversation.initialise(runtime.ledger(host))
  let info =
    conversation.Info(
      "durable",
      "title",
      "/tmp",
      "fixture",
      "model",
      types.Responses,
      "idle",
      None,
    )
  let assert Ok(_) = conversation.create(runtime.ledger(host), info)
  let history = [types.User("saved")]
  let assert Ok(_) =
    conversation.commit(runtime.ledger(host), "durable", history, "idle")
  let assert Ok(session) = runtime.open_session(host, "durable", "/tmp")
  let assert Ok([types.User(prefix), types.User("saved")]) =
    runtime.prepare_history(host, session, "model", history)
  string.contains(prefix, "ephemeral") |> should.be_true
  conversation.load(runtime.ledger(host), "durable")
  |> should.equal(Ok(history))
  runtime.stop(host)
}

// `remote` is a bundled default: one connection turns the session's tools into
// remote ones, and it degrades to plain commands rather than failing a session.
pub fn remote_is_installed_and_default_test() {
  let config = extensions.defaults()
  config.extensions
  |> list.map(fn(extension) { extension.name })
  |> list.contains("remote")
  |> should.be_true
  config.default_enabled |> list.contains("remote") |> should.be_true
}

pub fn model_provider_extensions_form_catalog_openai_codex_chain_test() {
  let config = extensions.defaults()
  let assert Ok(openai) =
    list.find(config.extensions, fn(item) { item.name == "openai" })
  let assert Ok(codex) =
    list.find(config.extensions, fn(item) { item.name == "codex" })
  openai.requires |> should.equal(["models"])
  codex.requires |> should.equal(["openai"])
  let catalog =
    extension.Extension(
      "catalog",
      "fixture catalog",
      [],
      [
        extension.ModelsPlugin(
          extension.ModelCatalog(fn(_, _) { None }, fn(provider, _) {
            case provider {
              "future-provider" -> ["catalog-model"]
              _ -> []
            }
          }),
        ),
      ],
      no_op,
    )
  let provider =
    extension.Extension(
      "future",
      "fixture provider",
      ["catalog"],
      [
        extension.ModelProviderPlugin(
          extension.ModelProvider("future-provider", fn(_) { None }),
        ),
      ],
      no_op,
    )
  extension.provider_model_names([catalog, provider], "future", "")
  |> should.equal(["catalog-model"])
  let assert Ok(host) = runtime.start_with_config(":memory:", config)
  let assert Ok(_) = runtime.open_session(host, "model-chain", "/tmp")
  runtime.reload_extension(host, "model-chain", "/tmp", "openai", False)
  |> should.equal(Error("codex requires enabled extension openai"))
  runtime.reload_extension(host, "model-chain", "/tmp", "models", False)
  |> should.equal(Error("openai requires enabled extension models"))
  runtime.stop(host)
}

// A context load that fails must not strand resources a managed plugin
// already opened: the failed composition owns nothing afterwards.
pub fn failed_context_leaves_no_prepared_resources_test() {
  let events = process.new_subject()
  let managed =
    extension.Extension(
      "managed",
      "fixture managed plugin",
      [],
      [
        extension.ManagedPlugin(fn(_, _, _) {
          process.send(events, "prepared")
          Ok(
            extension.Managed("", "", [], [], [], [], fn() {
              process.send(events, "closed")
            }),
          )
        }),
      ],
      no_op,
    )
  let failing =
    extension.Extension(
      "failing",
      "fixture context failure",
      [],
      [extension.ContextPlugin(fn(_) { Error("unreadable") })],
      no_op,
    )
  let assert Ok(host) =
    runtime.start_with_extensions(":memory:", [
      python.extension(),
      managed,
      failing,
    ])
  let assert Error(error) = runtime.open_session(host, "leak", "/tmp")
  string.inspect(error)
  |> string.contains("failing: unreadable")
  |> should.be_true
  let prepared = process.receive(events, 0) == Ok("prepared")
  case prepared {
    True -> process.receive(events, 0) |> should.equal(Ok("closed"))
    False -> Nil
  }
  runtime.stop(host)
}
