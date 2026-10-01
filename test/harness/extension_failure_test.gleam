//// A broken extension must cost only itself. Albedo loads third-party
//// extensions into the same session as its own, and a plugin that fails or
//// raises used to take the whole session with it: no tools, no turn, no
//// reply, and for a tool error a dead subagent. E2E cannot reach this,
//// because the daemon only loads albedo's own registry, so the rule is
//// checked here against deliberately broken extensions.

import albedo/daemon/conversation
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/runtime
import albedo/harness/tool
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

/// A session over `installed`, every one of them enabled.
fn host(
  installed: List(extension.Extension),
) -> #(runtime.Runtime, runtime.Session) {
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(
        installed,
        list.map(installed, fn(extension) { extension.name }),
      ),
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "broken-extension-test",
        "new session",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(session) =
    runtime.open_session(host, "broken-extension-test", "/tmp")
  #(host, session)
}

/// An extension whose only tool answers, named after it.
fn healthy(name: String) -> extension.Extension {
  extension.Extension(
    name,
    "answers",
    [],
    [extension.ToolPlugin("", [answering(name)], [], [])],
    extension.no_initialise,
  )
}

fn answering(name: String) -> extension.Tool {
  tool.text(
    name,
    "answers",
    False,
    [],
    [],
    decode.success(Nil),
    "usage",
    fn(_, _) { Ok("answered") },
  )
}

fn tool_only(name: String, value: extension.Tool) -> extension.Extension {
  extension.Extension(
    name,
    "one tool",
    [],
    [extension.ToolPlugin("", [value], [], [])],
    extension.no_initialise,
  )
}

fn plugin_only(name: String, plugin: extension.Plugin) -> extension.Extension {
  extension.Extension(name, "one plugin", [], [plugin], extension.no_initialise)
}

fn tool_names(session: runtime.Session) -> List(String) {
  runtime.tools(session) |> list.map(fn(tool) { tool.name })
}

fn warned_about(session: runtime.Session, name: String) -> Bool {
  runtime.warnings(session)
  |> list.any(fn(warning) { string.contains(warning, name) })
}

fn answer(
  host: runtime.Runtime,
  session: runtime.Session,
  name: String,
) -> String {
  let assert Ok(types.ToolOutput(_, body, _)) =
    runtime.invoke(
      host,
      session,
      types.ToolCall("call_1", name, "{}"),
      types.any_images,
    )
  body
}

pub fn a_failed_or_crashed_context_load_keeps_the_session_test() -> Nil {
  let #(host, session) =
    host([
      plugin_only("sulky", extension.ContextPlugin(fn(_) { Error("no root") })),
      plugin_only("exploding", extension.ContextPlugin(fn(_) { panic as "bug" })),
      healthy("working"),
    ])
  tool_names(session) |> should.equal(["working"])
  warned_about(session, "sulky") |> should.be_true
  warned_about(session, "exploding") |> should.be_true
  runtime.stop(host)
}

pub fn a_failed_or_crashed_prepare_keeps_the_session_test() -> Nil {
  let #(host, session) =
    host([
      plugin_only(
        "sulky",
        extension.ManagedPlugin(fn(_, _, _) { Error("no server") }),
      ),
      plugin_only(
        "exploding",
        extension.ManagedPlugin(fn(_, _, _) { panic as "bug" }),
      ),
      healthy("working"),
    ])
  tool_names(session) |> should.equal(["working"])
  warned_about(session, "sulky") |> should.be_true
  warned_about(session, "exploding") |> should.be_true
  runtime.stop(host)
}

/// A static collision is refused when the extension is selected; one a
/// managed plugin only discovers while preparing, as an MCP server's tool
/// list does, reaches the session and must lose there.
pub fn a_colliding_extension_loses_only_itself_test() -> Nil {
  let #(host, session) =
    host([
      healthy("echo"),
      plugin_only(
        "squatter",
        extension.ManagedPlugin(fn(_, _, _) {
          Ok(extension.Managed(..extension.empty(), tools: [answering("echo")]))
        }),
      ),
    ])
  tool_names(session) |> should.equal(["echo"])
  warned_about(session, "squatter") |> should.be_true
  answer(host, session, "echo") |> should.equal("answered")
  runtime.stop(host)
}

pub fn a_crashing_tool_answers_instead_of_ending_the_turn_test() -> Nil {
  let #(host, session) =
    host([
      tool_only(
        "exploding",
        extension.Tool(
          types.Tool("boom", "crashes", tool.schema([], []), False),
          fn(_, _) { panic as "tool bug" },
          fn(_) { None },
        ),
      ),
    ])
  let reason = error_of(answer(host, session, "boom"))
  string.contains(reason, "boom crashed") |> should.be_true
  string.contains(reason, "inspect") |> should.be_true
  runtime.stop(host)
}

pub fn a_fatal_tool_still_ends_the_turn_test() -> Nil {
  let #(host, session) =
    host([
      tool_only(
        "strict",
        extension.Tool(
          types.Tool("record", "cannot record", tool.schema([], []), False),
          fn(_, _) { Error(extension.Fatal("transcript storage failed")) },
          fn(_) { None },
        ),
      ),
    ])
  runtime.invoke(
    host,
    session,
    types.ToolCall("call_1", "record", "{}"),
    types.any_images,
  )
  |> should.equal(Error("transcript storage failed"))
  runtime.stop(host)
}

pub fn a_crashing_observer_leaves_the_session_working_test() -> Nil {
  let #(host, session) =
    host([
      plugin_only(
        "exploding",
        extension.ManagedPlugin(fn(_, _, _) {
          Ok(
            extension.Managed(..extension.empty(), observe: fn(_, _) {
              panic as "observer bug"
            }),
          )
        }),
      ),
      healthy("working"),
    ])
  runtime.observe(
    session,
    extension.Session("broken-extension-test", fn(_, _) { Error("no upstream") }),
    extension.Stirred,
  )
  answer(host, session, "working") |> should.equal("answered")
  runtime.stop(host)
}

fn error_of(body: String) -> String {
  let assert Ok(reason) =
    json.parse(body, decode.field("error", decode.string, decode.success))
  reason
}

/// An extension whose initialiser `fails`, for the quarantine cases.
fn uninstallable(name: String, fails: fn() -> Nil) -> extension.Extension {
  extension.Extension(
    name,
    "will not install",
    [],
    [extension.ToolPlugin("", [answering(name)], [], [])],
    fn(_) {
      fails()
      Error("no tables")
    },
  )
}

fn summary(
  host: runtime.Runtime,
  name: String,
) -> Result(extension.Summary, Nil) {
  let assert Ok(summaries) =
    runtime.extension_summaries(host, "broken-extension-test")
  list.find(summaries, fn(summary) { summary.name == name })
}

pub fn an_extension_that_cannot_install_is_quarantined_test() -> Nil {
  let #(host, session) =
    host([
      uninstallable("sulky", fn() { Nil }),
      uninstallable("exploding", fn() { panic as "initialiser bug" }),
      healthy("working"),
    ])
  tool_names(session) |> should.equal(["working"])
  let assert Ok(extension.Summary(quarantined: Some(reason), enabled: False, ..)) =
    summary(host, "sulky")
  string.contains(reason, "no tables") |> should.be_true
  let assert Ok(extension.Summary(quarantined: Some(crash), ..)) =
    summary(host, "exploding")
  string.contains(crash, "initialiser bug") |> should.be_true
  runtime.stop(host)
}

pub fn a_quarantined_requirement_takes_its_dependents_with_it_test() -> Nil {
  let #(host, session) =
    host([
      uninstallable("engine", fn() { Nil }),
      extension.Extension(
        "rider",
        "needs the engine",
        ["engine"],
        [extension.ToolPlugin("", [answering("rider")], [], [])],
        extension.no_initialise,
      ),
      healthy("working"),
    ])
  tool_names(session) |> should.equal(["working"])
  let assert Ok(extension.Summary(quarantined: Some(reason), ..)) =
    summary(host, "rider")
  string.contains(reason, "it requires engine") |> should.be_true
  runtime.stop(host)
}

pub fn a_quarantined_extension_cannot_be_enabled_test() -> Nil {
  let #(host, _) =
    host([uninstallable("sulky", fn() { Nil }), healthy("working")])
  let assert Error(refusal) =
    runtime.reload_extension(
      host,
      "broken-extension-test",
      "/tmp",
      "sulky",
      True,
    )
  string.contains(refusal, "quarantined") |> should.be_true
  runtime.stop(host)
}
