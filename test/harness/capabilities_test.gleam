import gleeunit/should

@external(erlang, "albedo_capabilities", "enabled")
fn enabled(
  home: String,
  session: String,
  kind: String,
  name: String,
) -> Result(Bool, String)

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn capabilities_global_and_session_override_test() {
  let #(root, _, home) = fixture()
  enabled(home, "first", "skills", "draft") |> should.equal(Ok(True))
  let _ =
    write(
      home,
      "capabilities.json",
      "{\"global\":{\"skills\":{\"draft\":false}},\"sessions\":{\"first\":{\"skills\":{\"draft\":true}}}}",
    )
  enabled(home, "first", "skills", "draft") |> should.equal(Ok(True))
  enabled(home, "other", "skills", "draft") |> should.equal(Ok(False))
  enabled(home, "first", "instructions", "project:AGENTS.md")
  |> should.equal(Ok(True))
  let _ = write(home, "capabilities.json", "{bad json}")
  enabled(home, "first", "skills", "draft")
  |> should.equal(Error("invalid capabilities.json"))
  cleanup(root)
}
