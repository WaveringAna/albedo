//// Daemon-owned persisted settings. Wire values are decoded before mutation.

import albedo/daemon/configuration
import albedo/harness/session_settings
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/result

pub fn capability_decoder() -> decode.Decoder(session_settings.Change) {
  use kind <- decode.field("kind", decode.string)
  use name <- decode.field("name", decode.string)
  use scope <- decode.field("scope", decode.string)
  use enabled <- decode.field("enabled", decode.optional(decode.bool))
  decode.success(session_settings.Capability(kind, name, scope, enabled))
}

pub fn save_provider(
  home: String,
  name: String,
  profile: String,
) -> Result(Nil, String) {
  use validated <- result.try(configuration.validate_profile(name, profile))
  provider(home, name, validated, False)
}

pub fn delete_provider(home: String, name: String) -> Result(Nil, String) {
  provider(home, name, "{}", True)
}

@external(erlang, "albedo_settings", "snapshot")
pub fn snapshot(home: String) -> Result(String, String)

@external(erlang, "albedo_settings", "provider")
fn provider(
  home: String,
  name: String,
  profile: String,
  delete: Bool,
) -> Result(Nil, String)

@external(erlang, "albedo_settings", "ui")
pub fn patch_ui(
  home: String,
  session: String,
  patch: String,
) -> Result(String, String)

@external(erlang, "albedo_settings", "open")
pub fn record_open(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_settings", "forget")
pub fn forget(home: String, session: String) -> Result(Nil, String)

@external(erlang, "albedo_settings", "encode_dynamic")
pub fn encode(value: Dynamic) -> String
