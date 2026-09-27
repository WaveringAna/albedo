//// Bounded, read-only access to this session's durable transcript rows, for
//// history an archive frame renders illegibly or its budget dropped.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/extension
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

pub fn definitions() -> List(extension.Tool) {
  [
    extension.Tool(
      types.Tool(
        "transcript_grep",
        "Find a case-insensitive literal term in this session's full durable transcript, including history archived out of the request. Results are paged and name each row's seq for transcript_read.",
        schema(["pattern"], [
          #("pattern", "string"),
          #("limit", "integer"),
          #("offset", "integer"),
        ]),
        False,
      ),
      fn(context, arguments) {
        let decoder = {
          use pattern <- decode.field("pattern", decode.string)
          use limit <- decode.optional_field("limit", 10, decode.int)
          use offset <- decode.optional_field("offset", 0, decode.int)
          decode.success(#(pattern, limit, offset))
        }
        case json.parse(arguments, decoder) {
          Ok(#(pattern, limit, offset)) ->
            grep(context.store, context.session, pattern, limit, offset)
            |> result.map(extension.text)
          Error(_) ->
            Ok(extension.text("expected pattern and optional limit, offset"))
        }
      },
      fn(_) { None },
    ),
    extension.Tool(
      types.Tool(
        "transcript_read",
        "Read a bounded page of this session's original transcript rows starting at seq. Use next_offset to continue; image payloads remain in the durable transcript.",
        schema(["seq"], [
          #("seq", "integer"),
          #("offset", "integer"),
          #("limit", "integer"),
        ]),
        False,
      ),
      fn(context, arguments) {
        let decoder = {
          use seq <- decode.field("seq", decode.int)
          use offset <- decode.optional_field("offset", 0, decode.int)
          use limit <- decode.optional_field("limit", 4000, decode.int)
          decode.success(#(seq, offset, limit))
        }
        case json.parse(arguments, decoder) {
          Ok(#(seq, offset, limit)) ->
            read(context.store, context.session, seq, offset, limit)
            |> result.map(extension.text)
          Error(_) ->
            Ok(extension.text("expected seq, optional offset and limit"))
        }
      },
      fn(_) { None },
    ),
  ]
}

fn schema(
  required: List(String),
  properties: List(#(String, String)),
) -> json.Json {
  json.object([
    #("type", json.string("object")),
    #("additionalProperties", json.bool(False)),
    #("required", json.array(required, json.string)),
    #(
      "properties",
      json.object(
        list.map(properties, fn(property) {
          #(property.0, json.object([#("type", json.string(property.1))]))
        }),
      ),
    ),
  ])
}

pub fn grep(
  ledger: store.Store,
  session: String,
  pattern: String,
  limit: Int,
  offset: Int,
) -> Result(String, String) {
  let pattern = string.trim(pattern)
  use _ <- result.try(case pattern != "" && string.length(pattern) <= 200 {
    True -> Ok(Nil)
    False -> Error("transcript search pattern must be 1..200 characters")
  })
  use _ <- result.try(case offset >= 0 {
    True -> Ok(Nil)
    False -> Error("transcript search offset must be nonnegative")
  })
  use sources <- result.try(conversation.load_sources(ledger, session))
  let needle = string.lowercase(pattern)
  let matches =
    list.filter(sources, fn(item) {
      string.contains(string.lowercase(row_text(item.entry.input)), needle)
    })
  let limit = int.min(20, int.max(1, limit))
  let next = offset + limit
  json.object([
    #("pattern", json.string(pattern)),
    #("offset", json.int(offset)),
    #("count", json.int(list.length(matches))),
    #("next_offset", case next < list.length(matches) {
      True -> json.int(next)
      False -> json.null()
    }),
    #(
      "rows",
      json.array(list.take(list.drop(matches, offset), limit), fn(item) {
        json.object([
          #("seq", json.int(item.source.seq)),
          #("preview", json.string(excerpt(row_text(item.entry.input), 400))),
        ])
      }),
    ),
  ])
  |> json.to_string
  |> Ok
}

pub fn read(
  ledger: store.Store,
  session: String,
  seq: Int,
  offset: Int,
  limit: Int,
) -> Result(String, String) {
  use _ <- result.try(case offset >= 0 {
    True -> Ok(Nil)
    False -> Error("transcript read offset must be nonnegative")
  })
  use sources <- result.try(conversation.load_sources(ledger, session))
  let limit = int.min(8000, int.max(1, limit))
  let rendered =
    sources
    |> list.filter(fn(item) { item.source.seq >= seq })
    |> list.map(fn(item) {
      "[row #"
      <> int.to_string(item.source.seq)
      <> "]\n"
      <> row_text(item.entry.input)
    })
    |> string.join("\n\n")
  let page = string.slice(rendered, offset, limit)
  let next = offset + string.length(page)
  json.object([
    #("seq", json.int(seq)),
    #("offset", json.int(offset)),
    #("content", json.string(page)),
    #("next_offset", case next < string.length(rendered) {
      True -> json.int(next)
      False -> json.null()
    }),
  ])
  |> json.to_string
  |> Ok
}

fn row_text(input: types.Input) -> String {
  case input {
    types.User(text) -> "[user]\n" <> text
    types.UserImage(text, image) ->
      "[user with " <> image_description(image) <> "]\n" <> text
    types.Assistant(text) -> "[assistant]\n" <> text
    types.ToolOutput(id, output, images) ->
      "[tool "
      <> id
      <> "]\n"
      <> output
      <> string.concat(
        list.map(images, fn(image) { "\n[" <> image_description(image) <> "]" }),
      )
    types.Replay(item) ->
      "[provider output]\n" <> json.to_string(types.replay_json(item))
  }
}

fn image_description(image: types.Image) -> String {
  let #(mime, width, height, _) = types.image_meta(image)
  mime <> " " <> int.to_string(width) <> "x" <> int.to_string(height)
}

fn excerpt(value: String, maximum: Int) -> String {
  case string.length(value) > maximum {
    True -> string.slice(value, 0, maximum) <> "…"
    False -> value
  }
}
