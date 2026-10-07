//// Daemon-owned persisted settings. Wire values are decoded before mutation.

import albedo/harness/oauth
import gleam/option.{type Option}

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

/// Whether saving `group` can change a session's composition. These are the
/// groups `composition_revision` hashes (albedo_settings_http.erl); the rest
/// never call for a reload.
pub fn composes(group: Group) -> Bool {
  case group {
    Extensions | MCP | Capabilities -> True
    Providers | Models | UI -> False
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
