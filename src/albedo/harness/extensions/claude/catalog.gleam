//// Claude models as the Anthropic Models API lists them for the signed-in
//// account, newest first, with their limits, image input, and efforts.
//// Nothing here names a model, so a new one appears once Anthropic lists it.

import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

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
  use rows <- result.try(native_fetch(header))
  save(home, normalize(rows))
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

/// Normalize upstream facts independently of the stricter disk decoder.
pub fn normalize(rows: List(Dynamic)) -> List(Model) {
  list.filter_map(rows, fn(row) {
    use id <- result.try(
      decode.run(row, decode.at(["id"], decode.string))
      |> result.replace_error(Nil),
    )
    case id {
      "" -> Error(Nil)
      _ ->
        Ok(Model(
          id,
          positive(row, "max_input_tokens"),
          positive(row, "max_tokens"),
          supported(row, ["capabilities", "image_input", "supported"]),
          efforts(row),
        ))
    }
  })
}

/// Save normalized models in the existing cache format.
pub fn save(home: String, models: List(Model)) -> Result(Nil, String) {
  models
  |> json.array(encode_model)
  |> json.to_string
  |> native_write(home, _)
}

fn encode_model(model: Model) -> json.Json {
  json.object([
    #("id", json.string(model.id)),
    #("context", json.nullable(model.context, json.int)),
    #("output", json.nullable(model.output, json.int)),
    #("images", json.bool(model.images)),
    #("efforts", json.array(model.efforts, json.string)),
  ])
}

fn positive(row: Dynamic, field: String) -> Option(Int) {
  case decode.run(row, decode.at([field], decode.int)) {
    Ok(value) if value > 0 -> Some(value)
    _ -> None
  }
}

fn supported(row: Dynamic, path: List(String)) -> Bool {
  decode.run(row, decode.at(path, decode.bool)) == Ok(True)
}

fn efforts(row: Dynamic) -> List(String) {
  case supported(row, ["capabilities", "effort", "supported"]) {
    False -> []
    True ->
      decode.run(
        row,
        decode.at(
          ["capabilities", "effort"],
          decode.dict(decode.string, decode.dynamic),
        ),
      )
      |> result.map(dict.to_list)
      |> result.unwrap([])
      |> list.filter_map(fn(entry) {
        let #(level, detail) = entry
        case level != "supported" && supported(detail, ["supported"]) {
          True -> Ok(level)
          False -> Error(Nil)
        }
      })
      |> list.sort(fn(left, right) {
        case int.compare(effort_rank(left), effort_rank(right)) {
          order.Eq -> string.compare(left, right)
          ordering -> ordering
        }
      })
  }
}

fn effort_rank(level: String) -> Int {
  case level {
    "minimal" -> 0
    "low" -> 1
    "medium" -> 2
    "high" -> 3
    "xhigh" -> 4
    "max" -> 5
    _ -> 6
  }
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

@external(erlang, "albedo_claude_models", "fetch")
fn native_fetch(header: #(String, String)) -> Result(List(Dynamic), String)

@external(erlang, "albedo_claude_models", "write")
fn native_write(home: String, encoded: String) -> Result(Nil, String)

@external(erlang, "albedo_claude_models", "refresh")
fn native_refresh(home: String, reload: fn() -> Result(Nil, String)) -> Nil

@external(erlang, "albedo_claude_models", "api_key")
fn native_api_key(home: String) -> Result(String, Nil)

@external(erlang, "albedo_claude_auth", "access")
fn native_access(home: String, session: String) -> Result(String, String)
