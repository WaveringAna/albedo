//// Daemon-owned persisted settings. Wire values are decoded before mutation.

import albedo/harness/oauth
import gleam/option.{type Option}
import gleam/result

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
