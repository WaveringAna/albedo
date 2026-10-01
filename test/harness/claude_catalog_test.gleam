//// Anthropic's authenticated endpoint cannot use the E2E loopback provider.
//// These fixtures catch forgiving upstream parsing and cache compatibility bugs.

import albedo/harness/extensions/claude/catalog
import gleam/dynamic
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

fn upstream() -> List(dynamic.Dynamic) {
  let assert Ok(rows) =
    json.parse(
      "[
      {\"id\":\"claude-fixture\",\"max_input_tokens\":200000,\"max_tokens\":64000,
       \"capabilities\":{\"image_input\":{\"supported\":true},\"effort\":{
         \"supported\":true,\"zeta\":{\"supported\":true},\"high\":{\"supported\":true},
         \"minimal\":{\"supported\":true},\"alpha\":{\"supported\":true},
         \"xhigh\":{\"supported\":true},\"medium\":{\"supported\":true},
         \"max\":{\"supported\":true},\"low\":{\"supported\":true},
         \"disabled\":{\"supported\":false},\"malformed\":{\"supported\":\"true\"}}}},
      {\"id\":\"\"},{\"id\":7},null,
      {\"id\":\"claude-fixture\",\"max_input_tokens\":-1,\"max_tokens\":\"100\",
       \"capabilities\":{\"image_input\":true,\"effort\":{\"supported\":false,\"high\":{\"supported\":true}}}},
      {\"id\":\"claude-last\",\"max_input_tokens\":1.5,\"capabilities\":[]}
    ]",
      decode.list(decode.dynamic),
    )
  rows
}

pub fn upstream_normalization_keeps_valid_order_duplicates_and_typed_facts_test() -> Nil {
  catalog.normalize(upstream())
  |> should.equal([
    catalog.Model("claude-fixture", Some(200_000), Some(64_000), True, [
      "minimal", "low", "medium", "high", "xhigh", "max", "alpha", "zeta",
    ]),
    catalog.Model("claude-fixture", None, None, False, []),
    catalog.Model("claude-last", None, None, False, []),
  ])
}

pub fn normalized_upstream_saves_a_readable_private_cache_test() -> Nil {
  let home = temporary_home()
  let models = catalog.normalize(upstream())
  catalog.save(home, models) |> should.equal(Ok(Nil))
  catalog.models(home) |> should.equal(models)
  cache_permissions(home) |> should.equal(0o600)
  catalog.save(home, []) |> should.equal(Ok(Nil))
  catalog.models(home) |> should.equal([])
  cleanup(home)
}

pub fn cache_write_failure_keeps_the_existing_error_test() -> Nil {
  let home = temporary_home()
  block_cache(home)
  catalog.save(home, catalog.normalize(upstream()))
  |> should.equal(Error("could not save the Claude model list"))
  cleanup(home)
}

@external(erlang, "albedo_claude_catalog_test_support", "temporary_home")
fn temporary_home() -> String

@external(erlang, "albedo_claude_catalog_test_support", "cache_permissions")
fn cache_permissions(home: String) -> Int

@external(erlang, "albedo_claude_catalog_test_support", "block_cache")
fn block_cache(home: String) -> Nil

@external(erlang, "albedo_claude_catalog_test_support", "cleanup")
fn cleanup(home: String) -> Nil
