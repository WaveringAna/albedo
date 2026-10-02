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
  choices(preferences, kind, name)
  |> result.map(fn(choices) { choices.2 })
}

pub fn validate_preferences(preferences: Preferences) -> Result(Nil, String) {
  case preferences {
    Unscoped -> Ok(Nil)
    Scoped(_, config) -> validate(config)
  }
}

/// Preserve absent choices separately from their resolved enabled default.
/// Readers validate only the requested choice; persisted settings are validated
/// in full before a mutation or snapshot.
pub fn choices(
  preferences: Preferences,
  kind: String,
  name: String,
) -> Result(#(Option(Bool), Option(Bool), Bool), String) {
  case preferences {
    Unscoped -> Ok(#(None, None, True))
    Scoped(session, config) -> {
      let choice = {
        use named <- decode.optional_field(
          name,
          None,
          decode.map(decode.bool, Some),
        )
        decode.success(named)
      }
      let group = decode.optional_field(kind, None, choice, decode.success)
      let decoder = {
        use global <- decode.optional_field("global", None, group)
        let selected =
          decode.optional_field(session, None, group, decode.success)
        use override <- decode.optional_field("sessions", None, selected)
        decode.success(#(
          global,
          override,
          option.unwrap(override, option.unwrap(global, True)),
        ))
      }
      decode.run(config, decoder)
      |> result.replace_error("invalid capabilities.json")
    }
  }
}

@external(erlang, "albedo_capabilities", "read")
fn read(home: String) -> Result(BitArray, String)

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
