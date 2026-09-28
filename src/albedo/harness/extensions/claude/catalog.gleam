//// Claude models as the Anthropic Models API lists them for the signed-in
//// account, newest first, with their limits, image input, and efforts.
//// Nothing here names a model, so a new one appears once Anthropic lists it.

import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None}
import gleam/result

pub type Model {
  Model(
    id: String,
    context: Option(Int),
    output: Option(Int),
    images: Bool,
    efforts: List(String),
  )
}

/// Refetches the list now with the Claude subscription, or else with the
/// Console key of the first claude profile that sets one.
pub fn reload(home: String) -> Result(Nil, String) {
  use header <- result.try(case native_access(home, "") {
    Ok(access) -> Ok(#("authorization", "Bearer " <> access))
    Error(error) ->
      native_api_key(home)
      |> result.map(fn(key) { #("x-api-key", key) })
      |> result.replace_error(error)
  })
  native_reload(home, header)
}

/// Refetches in the background when the cached list is missing or old.
pub fn refresh_later(home: String) -> Nil {
  native_refresh(home, fn() { reload(home) })
}

/// The cached list, empty before the first fetch lands.
pub fn models(home: String) -> List(Model) {
  native_read(home)
  |> result.try(fn(bytes) {
    json.parse_bits(bytes, decode.list(model_decoder()))
    |> result.replace_error(Nil)
  })
  |> result.unwrap([])
}

fn model_decoder() -> decode.Decoder(Model) {
  use id <- decode.field("id", decode.string)
  use context <- decode.optional_field(
    "context",
    None,
    decode.optional(decode.int),
  )
  use output <- decode.optional_field(
    "output",
    None,
    decode.optional(decode.int),
  )
  use images <- decode.optional_field("images", False, decode.bool)
  use efforts <- decode.optional_field(
    "efforts",
    [],
    decode.list(decode.string),
  )
  decode.success(Model(id, context, output, images, efforts))
}

@external(erlang, "albedo_claude_models", "read")
fn native_read(home: String) -> Result(BitArray, Nil)

@external(erlang, "albedo_claude_models", "reload")
fn native_reload(home: String, header: #(String, String)) -> Result(Nil, String)

@external(erlang, "albedo_claude_models", "refresh")
fn native_refresh(home: String, reload: fn() -> Result(Nil, String)) -> Nil

@external(erlang, "albedo_claude_models", "api_key")
fn native_api_key(home: String) -> Result(String, Nil)

@external(erlang, "albedo_claude_auth", "access")
fn native_access(home: String, session: String) -> Result(String, String)
