import albedo/harness/settings
import gleam/dynamic/decode
import gleeunit/should

pub fn settings_are_optional_typed_and_do_not_leak_values_test() {
  let #(root, _, home) = fixture()
  settings.load_at(home, "rolling", decode.int, 90) |> should.equal(Ok(90))
  let _ =
    write(
      home,
      "extensions.json",
      "{\"mcp\":{\"secret\":\"never-show-me\"},\"rolling\":75}",
    )
  settings.load_at(home, "rolling", decode.int, 90) |> should.equal(Ok(75))
  settings.load_at(home, "absent", decode.int, 90) |> should.equal(Ok(90))
  settings.load_at(home, "mcp", decode.int, 90)
  |> should.equal(Error("invalid settings for extension mcp"))
  let _ = write(home, "extensions.json", "[]")
  settings.load_at(home, "mcp", decode.int, 0)
  |> should.equal(Error("extensions.json must contain a JSON object"))
  let _ = write(home, "extensions.json", "{invalid secret}")
  settings.load_at(home, "mcp", decode.int, 0)
  |> should.equal(Error("extensions.json must contain a JSON object"))
  cleanup(root)
}

pub fn settings_file_is_bounded_test() {
  let #(root, _, home) = fixture()
  let _ = write_repeat(home, "extensions.json", "x", 1_048_577)
  settings.load_at(home, "mcp", decode.int, 0)
  |> should.equal(Error("extensions.json exceeds 1 MiB"))
  cleanup(root)
}

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "write_repeat")
fn write_repeat(
  base: String,
  relative: String,
  chunk: String,
  count: Int,
) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
