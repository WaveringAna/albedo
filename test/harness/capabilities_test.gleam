//// A loaded selection must remain stable across a concurrent file replacement.
//// E2E cannot deterministically replace preferences between two selection checks.

import albedo/harness/capabilities
import gleam/option.{None, Some}
import gleeunit/should

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn selection_snapshot_survives_replacement_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "capabilities.json",
      "{\"global\":{\"skills\":{\"demo\":false}},\"sessions\":{\"unrelated\":{\"mcp\":{\"broken\":\"yes\"}}}}",
    )
  let assert Ok(snapshot) = capabilities.load(home, Some("session"))
  capabilities.enabled(snapshot, "skills", "demo") |> should.equal(Ok(False))
  let _ =
    write(
      home,
      "capabilities.json",
      "{\"global\":{\"skills\":{\"demo\":true}}}",
    )
  capabilities.enabled(snapshot, "skills", "demo") |> should.equal(Ok(False))
  let assert Ok(updated) = capabilities.load(home, Some("session"))
  capabilities.enabled(updated, "skills", "demo") |> should.equal(Ok(True))
  let _ = write(home, "capabilities.json", "invalid json")
  let assert Ok(unscoped) = capabilities.load(home, None)
  capabilities.enabled(unscoped, "skills", "demo") |> should.equal(Ok(True))
  cleanup(root)
}
