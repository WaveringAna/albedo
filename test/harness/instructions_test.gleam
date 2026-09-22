import albedo/harness/extensions
import albedo/harness/instructions
import gleam/list
import gleam/string
import gleeunit/should

@external(erlang, "albedo_instructions_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_instructions_test_support", "empty_fixture")
fn empty_fixture() -> #(String, String, String)

@external(erlang, "albedo_instructions_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn installed_and_enabled_by_default_test() {
  let config = extensions.defaults()
  config.extensions
  |> list.map(fn(extension) { extension.name })
  |> list.contains("instructions")
  |> should.be_true
  config.default_enabled |> list.contains("instructions") |> should.be_true
}

pub fn project_and_global_files_are_concatenated_with_scope_test() {
  let #(root, project, home) = fixture()
  let assert Ok(context) = instructions.load_at(project, home)

  string.contains(context, "## Project-level conventions") |> should.be_true
  string.contains(context, "root project convention") |> should.be_true
  string.contains(context, "nested project convention") |> should.be_true
  string.contains(context, "albedo project convention") |> should.be_true
  string.contains(context, "## Global user preferences") |> should.be_true
  string.contains(context, "global preference one") |> should.be_true
  string.contains(context, "global preference two") |> should.be_true
  string.contains(context, "must not load") |> should.be_false
  context
  |> string.split("### AGENTS.md")
  |> list.length
  |> should.equal(2)

  cleanup(root)
}

pub fn no_instruction_files_produce_no_context_test() {
  let #(root, project, home) = empty_fixture()
  instructions.load_at(project, home) |> should.equal(Ok(""))
  cleanup(root)
}
