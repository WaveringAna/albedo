//// Authenticated fixed endpoints cannot use the E2E loopback provider. Scripted
//// HTTP responses and real files catch refresh ordering, retention, and failures.

import albedo/harness/extensions/codex/catalog
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string

@external(erlang, "albedo_codex_catalog_test_support", "temporary_home")
fn temporary_home() -> String

@external(erlang, "albedo_codex_catalog_test_support", "cleanup")
fn cleanup(home: String) -> Nil

@external(erlang, "albedo_codex_catalog_test_support", "seed")
fn seed(home: String, text: String) -> Nil

@external(erlang, "albedo_codex_catalog_test_support", "read")
fn read(home: String) -> BitArray

@external(erlang, "albedo_codex_catalog_test_support", "block_cache")
fn block_cache(home: String) -> Nil

@external(erlang, "albedo_codex_catalog_test_support", "permissions")
fn permissions(home: String) -> Int

@external(erlang, "albedo_codex_catalog_test_support", "script")
fn script(responses: List(Result(catalog.Response, Nil))) -> Nil

@external(erlang, "albedo_codex_catalog_test_support", "get")
fn get(
  url: String,
  headers: List(#(String, String)),
) -> Result(catalog.Response, Nil)

@external(erlang, "albedo_codex_catalog_test_support", "calls")
fn calls() -> List(#(String, List(#(String, String))))

fn response(status: Int, body: String) -> Result(catalog.Response, Nil) {
  Ok(catalog.Response(status, [#("etag", "one")], bit_array.from_string(body)))
}

const upstream = "{\"models\":[{\"slug\":\"reasoner\",\"display_name\":\"Reasoner\",\"context_window\":200000,\"max_context_window\":400000,\"input_modalities\":[\"text\",false,\"image\"],\"supported_reasoning_levels\":[{\"effort\":\"high\"},{\"effort\":4},{\"effort\":\"low\"}],\"priority\":7},{\"slug\":\"\"},{\"slug\":false},{\"slug\":\"reasoner\",\"display_name\":\"\",\"context_window\":-4,\"max_context_window\":\"wrong\",\"input_modalities\":{},\"visibility\":null,\"priority\":\"wrong\"}]}"

pub fn upstream_rows_keep_valid_duplicates_and_independent_facts_test() {
  let assert Ok(rows) =
    json.parse(upstream, {
      use rows <- decode.field("models", decode.list(decode.dynamic))
      decode.success(rows)
    })
  let assert [first, duplicate] = catalog.normalize(rows)
  let assert Some(200_000) = first.context
  let assert Some(400_000) = first.max_context
  let assert ["text", "image"] = first.input
  let assert ["high", "low"] = first.efforts
  let assert 7 = first.priority
  let assert "reasoner" = duplicate.name
  let assert None = duplicate.context
  let assert None = duplicate.max_context
  let assert [] = duplicate.input
  let assert False = duplicate.visible
}

pub fn refresh_orders_version_freshness_and_conditional_requests_test() {
  let home = temporary_home()
  script([response(200, "{\"version\":\"1.2.3\"}"), response(200, upstream)])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 1000, 10_000, get)
  let assert ["reasoner"] = catalog.listed(home)
  let assert Some(info) = catalog.lookup(home, "endpoint", "reasoner")
  let assert Some(200_000) = info.context_tokens
  let assert 384 = permissions(home)
  let before = read(home)
  script([])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 1000, 10_001, get)
  let assert [] = calls()
  let assert True = read(home) == before
  script([response(200, "{\"version\":\"1.2.3\"}"), response(304, "")])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 0, 10_002, get)
  let assert [_, #(_, headers)] = calls()
  let assert True = list.contains(headers, #("if-none-match", "one"))
  let assert ["reasoner"] = catalog.listed(home)
  script([response(200, "{\"version\":\"2.0.0\"}"), response(304, "")])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 1000, 11_002, get)
  let assert [_, #(url, headers)] = calls()
  let assert True = string.ends_with(url, "client_version=2.0.0")
  let assert False =
    list.any(headers, fn(header) { header.0 == "if-none-match" })
  cleanup(home)
}

pub fn untouched_malformed_accounts_survive_and_presentation_stays_strict_test() {
  let home = temporary_home()
  seed(
    home,
    "{\"accounts\":{\"broken\":{\"models\":[{\"slug\":42}]},\"account\":{\"models\":[{\"slug\":\"old\"}]}}}",
  )
  script([response(200, "{\"version\":\"1.2.3\"}"), response(200, upstream)])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 0, 10_000, get)
  let assert [] = catalog.listed(home)
  let assert Ok([42]) =
    json.parse_bits(
      read(home),
      decode.at(
        ["accounts", "broken", "models"],
        decode.list({
          use slug <- decode.field("slug", decode.int)
          decode.success(slug)
        }),
      ),
    )
  cleanup(home)
}

pub fn failed_models_save_version_but_preserve_models_and_error_precedence_test() {
  let home = temporary_home()
  seed(
    home,
    "{\"accounts\":{\"account\":{\"models\":[{\"slug\":\"old\"}],\"clientVersion\":\"1.0.0\",\"etag\":\"old-tag\"}},\"clientVersion\":\"1.0.0\"}",
  )
  script([response(200, "{\"version\":\"2.0.0\"}"), response(503, "")])
  let assert Error("Codex model list returned HTTP 503") =
    catalog.refresh_at(home, "access", "account", 0, 10_000, get)
  let assert ["old"] = catalog.listed(home)
  let assert Ok("2.0.0") =
    json.parse_bits(read(home), decode.at(["clientVersion"], decode.string))
  script([Error(Nil), response(304, "")])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 0, 10_001, get)
  let assert [_, #(url, _)] = calls()
  let assert True = string.ends_with(url, "client_version=2.0.0")
  script([response(200, "{\"version\":\"3.0.0\"}"), response(200, "{")])
  let assert Error("Codex model list is not valid") =
    catalog.refresh_at(home, "access", "account", 0, 10_002, get)
  let assert ["old"] = catalog.listed(home)
  let assert Ok("3.0.0") =
    json.parse_bits(read(home), decode.at(["clientVersion"], decode.string))
  cleanup(home)
  let blocked = temporary_home()
  block_cache(blocked)
  script([Error(Nil), response(200, upstream)])
  let assert Error("Codex model cache could not be written") =
    catalog.refresh_at(blocked, "access", "account", 0, 10_000, get)
  let assert [_, #(url, _)] = calls()
  let assert True = string.ends_with(url, "client_version=0.157.1")
  script([Error(Nil), Error(Nil)])
  let assert Error("Codex model list request failed") =
    catalog.refresh_at(blocked, "access", "account", 0, 10_000, get)
  cleanup(blocked)
}

pub fn version_check_precedes_fresh_entry_and_same_version_returns_without_write_test() {
  let home = temporary_home()
  seed(
    home,
    "{\"clientVersion\":\"1.0.0\",\"versionCheckedAt\":1000,\"accounts\":{\"account\":{\"fetchedAt\":1999,\"clientVersion\":\"1.0.0\",\"etag\":\"old\",\"models\":[{\"slug\":\"old\"}]}}}",
  )
  let before = read(home)
  script([response(200, "{\"version\":\"1.0.0\"}")])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 1000, 2000, get)
  let assert [_] = calls()
  let assert True = before == read(home)
  script([
    response(200, "{\"version\":\"2.0.0\"}"),
    response(200, "{\"models\":[]}"),
  ])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 1000, 2000, get)
  let assert [_, #(_, headers)] = calls()
  let assert False = list.contains(headers, #("if-none-match", "old"))
  let assert [] = catalog.listed(home)
  cleanup(home)
}

pub fn not_modified_retains_models_and_updates_metadata_before_replacement_test() {
  let home = temporary_home()
  seed(
    home,
    "{\"clientVersion\":\"1.0.0\",\"versionCheckedAt\":1000,\"accounts\":{\"account\":{\"fetchedAt\":1000,\"clientVersion\":\"1.0.0\",\"etag\":\"old\",\"models\":[{\"slug\":\"hidden\",\"visible\":false}]}}}",
  )
  script([response(200, "{\"version\":\"1.0.0\"}"), response(304, "")])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 0, 2000, get)
  let assert Ok(2000) =
    json.parse_bits(
      read(home),
      decode.at(["accounts", "account", "fetchedAt"], decode.int),
    )
  let assert Ok("1.0.0") =
    json.parse_bits(
      read(home),
      decode.at(["accounts", "account", "clientVersion"], decode.string),
    )
  let assert [] = catalog.listed(home)
  let assert Some(info) = catalog.lookup(home, "endpoint", "hidden")
  let assert "hidden" = info.model
  script([response(200, "{\"version\":\"2.0.0\"}"), response(200, upstream)])
  let assert Ok(Nil) =
    catalog.refresh_at(home, "access", "account", 0, 2001, get)
  let assert Ok(2001) =
    json.parse_bits(
      read(home),
      decode.at(["accounts", "account", "fetchedAt"], decode.int),
    )
  let assert Ok("2.0.0") =
    json.parse_bits(
      read(home),
      decode.at(["accounts", "account", "clientVersion"], decode.string),
    )
  cleanup(home)
}
