//// Read-only extension settings. Credentials never appear in decoder diagnostics.

import gleam/dict
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub fn load(
  name: String,
  decoder: decode.Decoder(a),
  default: a,
) -> Result(a, String) {
  load_at(home(), name, decoder, default)
}

fn load_at(
  home: String,
  name: String,
  decoder: decode.Decoder(a),
  default: a,
) -> Result(a, String) {
  use bytes <- result.try(read(home))
  use sections <- result.try(
    json.parse_bits(bytes, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("extensions.json must contain a JSON object"),
  )
  case dict.get(sections, name) {
    Error(_) -> Ok(default)
    Ok(value) ->
      decode.run(value, decoder)
      |> result.replace_error("invalid settings for extension " <> name)
  }
}

/// `$ALBEDO_HOME`, else `~/.albedo`: where extension-owned state belongs.
@external(erlang, "albedo_extension_settings", "home")
pub fn home() -> String

@external(erlang, "albedo_extension_settings", "read")
fn read(home: String) -> Result(BitArray, String)
