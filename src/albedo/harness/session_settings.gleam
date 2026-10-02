//// Persist capability and MCP choices while the runtime owns session reloads.

import albedo/harness/capability_catalog
import albedo/harness/extensions/mcp/extension as mcp
import gleam/option.{type Option}
import gleam/result

pub type Change {
  Capability(kind: String, name: String, scope: String, enabled: Option(Bool))
  Catalog(change: capability_catalog.Change)
  MCP(name: String, server: Option(String), secrets: String)
}

pub fn mutate(
  home: String,
  session: String,
  change: Change,
  extensions: fn() -> Result(capability_catalog.Extensions, String),
  after: fn() -> Result(a, String),
) -> Result(a, String) {
  case change {
    Catalog(change) ->
      capability_catalog.save(home, session, change, extensions, after)
    Capability(kind, name, scope, enabled) ->
      case
        name != ""
        && { kind == "skills" || kind == "instructions" || kind == "mcp" }
        && { scope == "global" || scope == "session" }
      {
        True -> capability(home, session, kind, name, #(scope, enabled), after)
        False ->
          Error("choose a capability kind, name, and global or session scope")
      }
    MCP(name, server, secrets) -> {
      use _ <- result.try(mcp.validate_settings(name, server, secrets))
      save_mcp(home, name, server, secrets, after)
    }
  }
}

@external(erlang, "albedo_settings_store", "capability")
fn capability(
  home: String,
  session: String,
  kind: String,
  name: String,
  value: #(String, Option(Bool)),
  after: fn() -> Result(a, String),
) -> Result(a, String)

@external(erlang, "albedo_settings_store", "mcp")
fn save_mcp(
  home: String,
  name: String,
  server: Option(String),
  secrets: String,
  after: fn() -> Result(a, String),
) -> Result(a, String)
