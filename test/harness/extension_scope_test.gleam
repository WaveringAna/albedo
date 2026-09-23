import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/python/extension as python
import albedo/harness/runtime
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

fn bundle() -> extension.Extension {
  extension.Extension(
    "bundle",
    "fixture extension",
    ["python"],
    [extension.ContextPlugin(fn(_) { Ok("bundle context") })],
    fn(_) { Ok(Nil) },
  )
}

fn state(host: runtime.Runtime, session: String) -> #(Bool, Bool, Bool) {
  let assert Ok(summaries) = runtime.extension_summaries(host, session)
  let assert Ok(summary) = list.find(summaries, fn(s) { s.name == "bundle" })
  #(summary.enabled, summary.overridden, summary.global_enabled)
}

pub fn sessions_follow_global_defaults_until_they_choose_test() {
  let #(root, _, home) = fixture()
  use <- with_home(home)
  let config =
    extensions.Config([python.extension(), bundle()], ["python", "bundle"])
  let assert Ok(host) = runtime.start_with_config(":memory:", config)
  let assert Ok(_) = runtime.open_session(host, "a", "/tmp")
  let assert Ok(_) = runtime.open_session(host, "b", "/tmp")

  // A global change reaches every session without its own choice.
  let assert Ok(Some(_)) =
    runtime.change_extension(
      host,
      "a",
      "/tmp",
      extension.SetGlobal("bundle", False),
    )
  state(host, "a") |> should.equal(#(False, False, False))
  state(host, "b") |> should.equal(#(False, False, False))
  read(home <> "/extensions.json")
  |> string.contains("\"enabled\":{\"bundle\":false}")
  |> should.be_true

  // Only a session toggle makes that session diverge.
  let assert Ok(Some(_)) =
    runtime.change_extension(
      host,
      "a",
      "/tmp",
      extension.SetSession("bundle", True),
    )
  state(host, "a") |> should.equal(#(True, True, False))
  state(host, "b") |> should.equal(#(False, False, False))

  // A global change the session already matches keeps its kernel.
  runtime.change_extension(
    host,
    "a",
    "/tmp",
    extension.SetGlobal("bundle", True),
  )
  |> should.equal(Ok(None))
  state(host, "b") |> should.equal(#(True, False, True))

  // Dropping the choice follows the global default again.
  runtime.change_extension(host, "a", "/tmp", extension.Inherit("bundle"))
  |> should.equal(Ok(None))
  state(host, "a") |> should.equal(#(True, False, True))

  // A default that would break a dependency is refused and not saved.
  let assert Error(_) =
    runtime.change_extension(
      host,
      "b",
      "/tmp",
      extension.SetGlobal("python", False),
    )
  read(home <> "/extensions.json")
  |> string.contains("\"python\"")
  |> should.be_false

  runtime.stop(host)
  cleanup(root)
}
