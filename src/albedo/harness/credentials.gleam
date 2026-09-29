//// creds.json, the one file holding every secret albedo keeps. Only the
//// daemon reads or writes it: clients change provider keys and MCP server
//// secrets through these calls and only ever learn which ones are saved.

import gleam/dynamic.{type Dynamic}

pub type Summary {
  Summary(
    /// Profiles with a saved apiKey.
    providers: List(String),
    servers: List(Server),
  )
}

/// An MCP server's saved secrets, by name only.
pub type Server {
  Server(
    name: String,
    bearer_token: Bool,
    headers: List(String),
    env: List(String),
  )
}

/// Moves secrets still kept in auth.json, mcp-credentials.json or config.json
/// into creds.json, the old files into backups/ with `stamp` in their names.
/// Returns the files it moved secrets from.
@external(erlang, "albedo_credentials", "migrate")
pub fn migrate(home: String, stamp: String) -> Result(List(String), String)

@external(erlang, "albedo_credentials", "summary")
pub fn summary(home: String) -> Result(Summary, String)

/// Saves a profile's apiKey; an empty key removes it.
@external(erlang, "albedo_credentials", "put_provider_key")
pub fn put_provider_key(
  home: String,
  profile: String,
  key: String,
) -> Result(Nil, String)

/// Changes one server's secrets: an absent field keeps its value, null
/// removes it, and "headers" and "env" map names to a value or null. Returns
/// the token `undo_mcp` takes to put the previous secrets back.
@external(erlang, "albedo_credentials", "patch_mcp")
pub fn patch_mcp(
  home: String,
  server: String,
  patch: Dynamic,
) -> Result(String, String)

@external(erlang, "albedo_credentials", "undo_mcp")
pub fn undo_mcp(
  home: String,
  server: String,
  token: String,
) -> Result(Nil, String)

/// The files this daemon's start moved secrets out of, reported once so the
/// first client to ask tells the user where the old copies went.
@external(erlang, "albedo_credentials", "take_migrated")
pub fn take_migrated() -> List(String)
