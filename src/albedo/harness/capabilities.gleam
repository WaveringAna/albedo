//// Capability preferences: session choices override global defaults.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub opaque type Preferences {
  Unscoped
  Scoped(session: String, config: Dynamic)
}

/// Load one immutable snapshot for a selection operation.
pub fn load(
  home: String,
  session: Option(String),
) -> Result(Preferences, String) {
  case session {
    None -> Ok(Unscoped)
    Some(session) -> {
      use bytes <- result.try(read(home))
      json.parse_bits(bytes, decode.dynamic)
      |> result.replace_error("invalid capabilities.json")
      |> result.map(fn(config) { Scoped(session, config) })
    }
  }
}

/// Unspecified capabilities are enabled.
pub fn enabled(
  preferences: Preferences,
  kind: String,
  name: String,
) -> Result(Bool, String) {
  case preferences {
    Unscoped -> Ok(True)
    Scoped(session, config) ->
      decode.run(config, selected_decoder(session, kind, name))
      |> result.replace_error("invalid capabilities.json")
  }
}

@external(erlang, "albedo_capabilities", "read")
fn read(home: String) -> Result(BitArray, String)

// Readers check only the requested choice; persisted settings are validated
// in full before a mutation or snapshot.
fn selected_decoder(
  session: String,
  kind: String,
  name: String,
) -> decode.Decoder(Bool) {
  use default <- decode.optional_field(
    "global",
    True,
    choice_decoder(kind, name, True),
  )
  let session_decoder = {
    use enabled <- decode.optional_field(
      session,
      default,
      choice_decoder(kind, name, default),
    )
    decode.success(enabled)
  }
  use enabled <- decode.optional_field("sessions", default, session_decoder)
  decode.success(enabled)
}

fn choice_decoder(
  kind: String,
  name: String,
  default: Bool,
) -> decode.Decoder(Bool) {
  let named_decoder = {
    use enabled <- decode.optional_field(name, default, decode.bool)
    decode.success(enabled)
  }
  use enabled <- decode.optional_field(kind, default, named_decoder)
  decode.success(enabled)
}

/// Validate every known capability group while allowing unrelated fields.
pub fn validate(config: Dynamic) -> Result(Nil, String) {
  use fields <- result.try(object(config))
  use global <- result.try(section(fields, "global"))
  use sessions <- result.try(section(fields, "sessions"))
  use _ <- result.try(validate_scope(global))
  list.try_each(dict.values(sessions), fn(scope) {
    use fields <- result.try(object(scope))
    validate_scope(fields)
  })
}

fn validate_scope(fields: Dict(String, Dynamic)) -> Result(Nil, String) {
  list.try_each(["skills", "instructions", "mcp"], fn(kind) {
    use choices <- result.try(section(fields, kind))
    list.try_each(dict.values(choices), fn(value) {
      decode.run(value, decode.bool)
      |> result.replace_error("invalid settings")
      |> result.map(fn(_) { Nil })
    })
  })
}

fn object(value: Dynamic) -> Result(Dict(String, Dynamic), String) {
  decode.run(value, decode.dict(decode.string, decode.dynamic))
  |> result.replace_error("invalid settings")
}

fn section(
  fields: Dict(String, Dynamic),
  key: String,
) -> Result(Dict(String, Dynamic), String) {
  case dict.get(fields, key) {
    Error(_) -> Ok(dict.new())
    Ok(value) ->
      object(value) |> result.replace_error("invalid settings section")
  }
}
