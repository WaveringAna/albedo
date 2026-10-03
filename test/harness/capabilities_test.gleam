//// A loaded selection must remain stable across a concurrent file replacement.
//// E2E cannot deterministically replace preferences between two selection checks.

import albedo/daemon/store
import albedo/harness/capabilities
import gleam/option.{None, Some}
import gleeunit/should
import sqlight

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

pub fn selection_snapshot_survives_replacement_test() -> Nil {
  let #(root, _, home) = fixture()
  let assert Ok(ledger) =
    store.start(
      root <> "/preferences.db",
      "CREATE TABLE session_selection(session TEXT,kind TEXT,preference_key TEXT,enabled INTEGER)",
    )
  let _ =
    write(
      home,
      "capabilities.json",
      "{\"global\":{\"skills\":{\"demo\":false}}}",
    )
  let assert Ok(snapshot) = capabilities.load(home, Some(#(ledger, "session")))
  capabilities.enabled(snapshot, "skills", "demo") |> should.equal(Ok(False))
  let _ =
    write(
      home,
      "capabilities.json",
      "{\"global\":{\"skills\":{\"demo\":true}}}",
    )
  capabilities.enabled(snapshot, "skills", "demo") |> should.equal(Ok(False))
  let assert Ok(updated) = capabilities.load(home, Some(#(ledger, "session")))
  capabilities.enabled(updated, "skills", "demo") |> should.equal(Ok(True))
  let assert Ok(_) =
    store.write(ledger, "INSERT INTO session_selection VALUES(?,?,?,?)", [
      sqlight.text("session"),
      sqlight.text("skills"),
      sqlight.text("demo"),
      sqlight.int(0),
    ])
  capabilities.enabled(updated, "skills", "demo") |> should.equal(Ok(True))
  let assert Ok(overridden) =
    capabilities.load(home, Some(#(ledger, "session")))
  capabilities.enabled(overridden, "skills", "demo") |> should.equal(Ok(False))
  let _ = write(home, "capabilities.json", "invalid json")
  let assert Ok(unscoped) = capabilities.load(home, None)
  capabilities.enabled(unscoped, "skills", "demo") |> should.equal(Ok(True))
  store.close(ledger)
  cleanup(root)
}
