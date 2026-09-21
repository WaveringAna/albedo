//// Compatible-provider reasoning fields. Preserve their names and opaque metadata.

import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

pub opaque type State {
  State(text: Dict(String, List(String)), details: Dict(Int, Detail))
}

pub opaque type Delta {
  Delta(text: Dict(String, String), details: List(DetailDelta))
}

type Detail {
  Detail(
    kind: String,
    fields: Dict(String, Dynamic),
    fragments: Dict(String, List(String)),
  )
}

type DetailDelta {
  DetailDelta(
    index: Int,
    kind: String,
    fields: Dict(String, Dynamic),
    fragments: Dict(String, String),
  )
}

pub fn new() -> State {
  State(dict.new(), dict.new())
}

pub fn decoder() -> decode.Decoder(Delta) {
  use text <- decode.then(strings(["reasoning", "reasoning_content"]))
  use details <- decode.optional_field(
    "reasoning_details",
    [],
    decode.optional(decode.list(detail_decoder()))
      |> decode.map(fn(value) {
        case value {
          Some(items) -> items
          None -> []
        }
      }),
  )
  decode.success(Delta(text, details))
}

fn detail_decoder() -> decode.Decoder(DetailDelta) {
  use fields <- decode.then(decode.dict(decode.string, decode.dynamic))
  use index <- decode.field("index", decode.int)
  use kind <- decode.field("type", decode.string)
  use fragments <- decode.then(
    strings(["text", "summary", "data", "signature"]),
  )
  case index >= 0 {
    True -> decode.success(DetailDelta(index, kind, fields, fragments))
    False ->
      decode.failure(
        DetailDelta(index, kind, fields, fragments),
        "nonnegative reasoning index",
      )
  }
}

fn strings(keys: List(String)) -> decode.Decoder(Dict(String, String)) {
  case keys {
    [] -> decode.success(dict.new())
    [key, ..rest] -> {
      use value <- decode.optional_field(
        key,
        None,
        decode.optional(decode.string),
      )
      use fields <- decode.then(strings(rest))
      decode.success(case value {
        None -> fields
        Some(value) -> dict.insert(fields, key, value)
      })
    }
  }
}

pub fn append(state: State, delta: Delta) -> Result(State, types.Error) {
  let Delta(text, details) = delta
  use details <- result.try(
    list.try_fold(details, state.details, fn(acc, delta) {
      let old =
        dict.get(acc, delta.index)
        |> result.unwrap(Detail(delta.kind, dict.new(), dict.new()))
      case old.kind == delta.kind {
        False ->
          Error(types.InvalidEvent(
            "reasoning detail type changed at the same index",
          ))
        True ->
          Ok(dict.insert(
            acc,
            delta.index,
            Detail(
              delta.kind,
              dict.merge(old.fields, delta.fields),
              append_text(old.fragments, delta.fragments),
            ),
          ))
      }
    }),
  )
  Ok(State(append_text(state.text, text), details))
}

fn append_text(
  acc: Dict(String, List(String)),
  delta: Dict(String, String),
) -> Dict(String, List(String)) {
  dict.fold(delta, acc, fn(acc, name, text) {
    let previous = dict.get(acc, name) |> result.unwrap([])
    dict.insert(acc, name, [text, ..previous])
  })
}

fn flatten(fragments: List(String)) -> Dynamic {
  fragments |> list.reverse |> string.concat |> dynamic.string
}

pub fn fields(state: State) -> List(#(Dynamic, Dynamic)) {
  let fields =
    dict.fold(state.text, [], fn(acc, key, values) {
      [#(dynamic.string(key), flatten(values)), ..acc]
    })
  case dict.is_empty(state.details) {
    True -> fields
    False -> {
      let details =
        state.details
        |> dict.to_list
        |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
        |> list.map(fn(entry) {
          let detail = entry.1
          let fields =
            dict.fold(detail.fragments, detail.fields, fn(fields, key, chunks) {
              dict.insert(fields, key, flatten(chunks))
            })
          fields
          |> dict.to_list
          |> list.map(fn(pair) { #(dynamic.string(pair.0), pair.1) })
          |> dynamic.properties
        })
      [#(dynamic.string("reasoning_details"), dynamic.list(details)), ..fields]
    }
  }
}

/// The incremental reasoning text to display, if this delta carried any.
/// Providers expose the same thought under different names; pick one canonical
/// source so a single thought is never streamed twice.
pub fn stream_text(delta: Delta) -> String {
  case canonical(delta.text) {
    "" -> detail_text(delta.details)
    text -> text
  }
}

fn canonical(text: Dict(String, String)) -> String {
  case dict.get(text, "reasoning_content"), dict.get(text, "reasoning") {
    Ok(value), _ -> value
    Error(_), Ok(value) -> value
    Error(_), Error(_) -> ""
  }
}

fn detail_text(details: List(DetailDelta)) -> String {
  details
  |> list.map(fn(detail) {
    case
      dict.get(detail.fragments, "text"),
      dict.get(detail.fragments, "summary")
    {
      Ok(value), _ -> value
      Error(_), Ok(value) -> value
      Error(_), Error(_) -> ""
    }
  })
  |> string.concat
}

pub fn empty_delta() -> Delta {
  Delta(dict.new(), [])
}
