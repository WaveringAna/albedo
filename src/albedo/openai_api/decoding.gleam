//// Decode diagnostics contain types and field paths, never provider values.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

pub fn json_error(error: json.DecodeError) -> String {
  case error {
    json.UnexpectedEndOfInput -> "unexpected end of JSON"
    json.UnexpectedByte(_) -> "unexpected JSON byte"
    json.UnexpectedSequence(_) -> "unexpected JSON sequence"
    json.UnableToDecode(errors) -> decode_errors(errors)
  }
}

pub fn decode_errors(errors: List(decode.DecodeError)) -> String {
  errors
  |> list.map(fn(error) {
    let path = case error.path {
      [] -> "$"
      fields -> "$." <> string.join(fields, ".")
    }
    path <> ": expected " <> error.expected <> ", found " <> error.found
  })
  |> string.join("; ")
}
