//// Daemon-owned persisted settings. Wire values are decoded before mutation.

import albedo/harness/cache_ttl
import albedo/harness/oauth
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/uri

pub type Group {
  Providers
  MCP
  Extensions
  Capabilities
  Models
  UI
}

pub fn parse_group(name: String) -> Result(Group, String) {
  case name {
    "providers" -> Ok(Providers)
    "mcp" -> Ok(MCP)
    "extensions" -> Ok(Extensions)
    "capabilities" -> Ok(Capabilities)
    "models" -> Ok(Models)
    "ui" -> Ok(UI)
    _ -> Error("unknown settings group")
  }
}

pub type GroupSnapshot {
  GroupSnapshot(value: String, etag: Option(String))
}

@external(erlang, "albedo_settings_http", "observe")
pub fn observe_group(
  home: String,
  group: String,
) -> Result(GroupSnapshot, #(Int, String, String))

@external(erlang, "albedo_settings_http", "composition_revision")
fn saved_composition_revision(
  home: String,
) -> Result(String, #(Int, String, String))

pub fn composition_revision(home: String) -> Result(String, String) {
  saved_composition_revision(home)
  |> result.map_error(fn(_) { "composition settings are unavailable" })
}

@external(erlang, "albedo_settings_http", "patch")
pub fn patch_group(
  home: String,
  group: String,
  etag: String,
  patch: String,
  providers: List(String),
  logins: List(oauth.Login),
  resolve: fn(String) -> Result(String, String),
  defaults: fn(List(#(String, Bool)), List(#(String, Option(Bool)))) ->
    Result(List(#(String, Bool)), #(Int, String, String)),
) -> Result(String, #(Int, String, String))

@external(erlang, "albedo_settings_http", "mcp_definitions")
pub fn mcp_definitions(
  home: String,
) -> Result(List(#(String, Bool)), #(Int, String, String))

/// Public cache priors use the same lookup as model requests.
pub fn cache_prior_json(
  provider: String,
  provider_extension: String,
  endpoint: String,
  model: String,
) -> String {
  let host =
    uri.parse(endpoint)
    |> result.map(fn(uri) { uri.host })
    |> result.unwrap(None)
    |> option.unwrap("")
  let entry = cache_ttl.lookup(provider_extension, host, model)
  let seconds =
    option.then(entry, cache_ttl.clock_tier)
    |> option.map(fn(tier) { tier.seconds })
  json.object([
    #("provider", json.string(provider)),
    #("model", json.string(model)),
    #("ttl_seconds", json.nullable(seconds, json.int)),
    #(
      "source",
      json.string(case entry {
        Some(entry) -> entry.source
        None -> "unknown"
      }),
    ),
  ])
  |> json.to_string
}
