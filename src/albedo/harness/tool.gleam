//// Shared ceremony for read-only retrieval tools: one place for the JSON
//// argument schema, the decode-and-usage wrapper, and the transcript text
//// rendering and paging every such tool repeats. Searching lives in
//// `albedo/harness/search`.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

/// An object schema whose properties are all simple named types.
pub fn schema(
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

/// One tool whose decoded arguments reach `run` directly and whose answer is
/// text: the schema, the argument decoding, the usage reply for undecodable
/// arguments, and the no-op recover, written once.
pub fn text(
  name: String,
  description: String,
  strict: Bool,
  required: List(String),
  properties: List(#(String, String)),
  decoder: decode.Decoder(arguments),
  usage: String,
  run: fn(extension.Context, arguments) -> Result(String, String),
) -> extension.Tool {
  extension.Tool(
    types.Tool(name, description, schema(required, properties), strict),
    fn(context, arguments) {
      case json.parse(arguments, decoder) {
        Ok(decoded) -> run(context, decoded) |> result.map(extension.text)
        Error(_) -> Ok(extension.text(usage))
      }
    },
    fn(_) { None },
  )
}

/// The text of a transcript input, as retrieval tools show it.
pub fn row_text(input: types.Input) -> String {
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

/// `value` cut to `maximum` graphemes with an ellipsis.
pub fn excerpt(value: String, maximum: Int) -> String {
  case string.length(value) > maximum {
    True -> string.slice(value, 0, maximum) <> "…"
    False -> value
  }
}

/// The `next_offset` field of a paged answer: the next position while rows
/// remain, null at the end.
pub fn next_offset(next: Int, more: Bool) -> json.Json {
  case more {
    True -> json.int(next)
    False -> json.null()
  }
}

/// One page of `rendered` starting at `offset`, at most 8000 graphemes, and
/// the offset the next page starts at.
pub fn text_page(rendered: String, offset: Int, limit: Int) -> #(String, Int) {
  let page = string.slice(rendered, offset, int.clamp(limit, 1, 8000))
  #(page, offset + string.length(page))
}

/// One text page of `session`'s durable transcript rows from `seq` on.
pub fn transcript_read(
  ledger: store.Store,
  session: String,
  seq: Int,
  offset: Int,
  limit: Int,
) -> Result(json.Json, String) {
  use _ <- result.try(compaction.require(
    offset >= 0,
    "transcript read offset must be nonnegative",
  ))
  use sources <- result.try(conversation.load_sources(ledger, session))
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
  let #(page, next) = text_page(rendered, offset, limit)
  Ok(
    json.object([
      #("seq", json.int(seq)),
      #("offset", json.int(offset)),
      #("content", json.string(page)),
      #("next_offset", next_offset(next, next < string.length(rendered))),
    ]),
  )
}
