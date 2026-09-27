import albedo/harness/command
import albedo/harness/extension
import albedo/harness/extensions/commands/extension as commands
import gleam/dict
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_env_test_support", "with_home")
fn with_home(home: String, run: fn() -> a) -> a

@external(erlang, "albedo_env_test_support", "read")
fn read(path: String) -> String

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

fn info(model: String, max: option.Option(Int)) -> extension.ModelInfo {
  extension.ModelInfo(
    model: model,
    provider: "codex",
    context_tokens: Some(272_000),
    max_context_tokens: max,
    max_output_tokens: None,
    input_modalities: [],
    endpoint: None,
    environment: [],
    source: "test",
    efforts: [],
  )
}

fn raise_cap() -> command.Command {
  let assert Ok(found) =
    commands.extension().plugins
    |> list.flat_map(fn(plugin) {
      case plugin {
        extension.CommandPlugin(commands) -> commands
        _ -> []
      }
    })
    |> list.find(fn(command) { command.name == "/raise-cap" })
  found
}

/// A session's model, as the session bridge answers ModelGet.
fn session_on(model: String) -> command.Context {
  command.Context(fn(op) {
    case op {
      command.ModelGet -> Ok(json.object([#("model", json.string(model))]))
      _ -> Error("unexpected state call")
    }
  })
}

fn run(args: List(#(String, String))) {
  raise_cap().run(
    session_on("gpt-6-astra"),
    command.UserCall,
    dict.from_list(args),
  )
}

pub fn the_default_window_holds_until_the_cap_is_raised_test() {
  let #(root, _, home) = fixture()
  use <- with_home(home)
  let astra = info("gpt-6-astra", Some(872_000))
  extension.window(astra) |> should.equal(Some(272_000))
  let assert Ok(_) = extension.raise_cap("gpt-6-astra", True)
  extension.window(astra) |> should.equal(Some(872_000))
  // A model with nothing past its default window is not raised by the setting.
  let assert Ok(_) = extension.raise_cap("gpt-5.5", True)
  extension.window(info("gpt-5.5", None)) |> should.equal(Some(272_000))
  let assert Ok(_) = extension.raise_cap("gpt-6-astra", False)
  extension.window(astra) |> should.equal(Some(272_000))
  read(home <> "/extensions.json")
  |> string.contains("gpt-6-astra")
  |> should.be_false
  cleanup(root)
}

pub fn raise_cap_toggles_this_sessions_model_test() {
  let #(root, _, home) = fixture()
  use <- with_home(home)
  let assert Ok(command.Data(_)) = run([])
  extension.raised_caps() |> should.equal(["gpt-6-astra"])
  let assert Ok(_) = run([])
  extension.raised_caps() |> should.equal([])
  // An explicit state and model do not toggle.
  let assert Ok(_) = run([#("state", "on"), #("model", "gpt-6-sol")])
  let assert Ok(_) = run([#("state", "on"), #("model", "gpt-6-sol")])
  extension.raised_caps() |> should.equal(["gpt-6-sol"])
  let assert Error(_) = run([#("state", "sideways")])
  // The cap is the user's choice, never the model's.
  let assert Error(_) =
    raise_cap().run(session_on("gpt-6-astra"), command.ModelCall, dict.new())
  cleanup(root)
}
