//// Shared ceremony for read-only retrieval tools: one place for the JSON
//// argument schema, the decode-and-usage wrapper, and the transcript text
//// rendering and paging every such tool repeats. Searching lives in
//// `albedo/harness/search`.

import albedo/daemon/conversation
import albedo/daemon/message_content
import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/openai_api/types
import albedo/text_scalars
import gleam/dict
import gleam/dynamic/decode
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
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
/// arguments, and the no-op recover, written once. These reads are refusals
/// when they fail, never a reason to end the turn.
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
        Ok(decoded) ->
          run(context, decoded)
          |> result.map(extension.text)
          |> result.map_error(extension.Refused)
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
    types.UserImage(text, images) ->
      "[user with "
      <> string.join(list.map(images, image_description), ", ")
      <> "]\n"
      <> text
    types.Assistant(text) -> "[assistant]\n" <> text
    types.ToolOutput(id, output, images) ->
      "[tool "
      <> id
      <> "]\n"
      <> output
      <> string.concat(
        list.map(images, fn(image) { "\n[" <> image_description(image) <> "]" }),
      )
    types.Replay(item) -> "[assistant]\n" <> replay_text(input, item)
  }
}

/// An assistant output as a person reads it: its text, its reasoning once,
/// and each call with its arguments unescaped. The opaque fields a provider
/// needs back (signatures, encrypted reasoning) and the copies of the same
/// text it repeats them in are left out; the durable row keeps them.
fn replay_text(input: types.Input, item: types.ReplayItem) -> String {
  let text = case message_content.visible_assistant_text(input) {
    Some(text) -> [text]
    None -> []
  }
  let thinking = case string.trim(message_content.thinking_text(item)) {
    "" -> []
    reasoning -> ["[thinking]\n" <> reasoning]
  }
  let calls =
    list.map(message_content.calls(input), fn(call) {
      "[call " <> call.name <> "]\n" <> arguments_text(call.arguments)
    })
  case list.flatten([text, thinking, calls]) {
    [] ->
      "(provider data only, "
      <> int.to_string(types.replay_bytes(item))
      <> " bytes)"
    parts -> string.join(parts, "\n\n")
  }
}

/// A call's arguments with each value unescaped, so code reads as code; one
/// that is not a flat object stays as the provider sent it.
fn arguments_text(arguments: String) -> String {
  let scalar =
    decode.one_of(decode.string, [
      decode.map(decode.int, int.to_string),
      decode.map(decode.float, float.to_string),
      decode.map(decode.bool, fn(flag) {
        case flag {
          True -> "true"
          False -> "false"
        }
      }),
    ])
  case json.parse(arguments, decode.dict(decode.string, scalar)) {
    Ok(fields) ->
      dict.to_list(fields)
      |> list.sort(fn(a, b) { string.compare(a.0, b.0) })
      |> list.map(fn(field) {
        case string.contains(field.1, "\n") {
          True -> field.0 <> ":\n" <> field.1
          False -> field.0 <> ": " <> field.1
        }
      })
      |> string.join("\n")
    Error(_) -> arguments
  }
}

fn image_description(image: types.Image) -> String {
  let #(mime, width, height, _) = types.image_meta(image)
  mime <> " " <> int.to_string(width) <> "x" <> int.to_string(height)
}

/// `value` cut to `maximum` scalars with an ellipsis.
pub fn excerpt(value: String, maximum: Int) -> String {
  case text_scalars.length(value) > maximum {
    True -> text_scalars.take(value, maximum) <> "…"
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

/// One text page of `session`'s durable transcript rows from `seq` on, or
/// through `through` when given.
pub fn transcript_read(
  ledger: store.Store,
  session: String,
  seq: Int,
  through: Option(Int),
  offset: Int,
  limit: Int,
) -> Result(json.Json, String) {
  use _ <- result.try(compaction.require(
    offset >= 0,
    "transcript read offset must be nonnegative",
  ))
  use _ <- result.try(compaction.require(
    option.unwrap(through, seq) >= seq,
    "transcript read through must not be before seq",
  ))
  use snapshot <- result.try(conversation.snapshot(ledger, session))
  use #(page, next, more) <- result.try(source_page(
    ledger,
    snapshot,
    seq,
    int.min(option.unwrap(through, snapshot.upper), snapshot.upper),
    "row",
    offset,
    limit,
  ))
  Ok(
    json.object([
      #("seq", json.int(seq)),
      #("offset", json.int(offset)),
      #("content", json.string(page)),
      #("next_offset", next_offset(next, more)),
    ]),
  )
}

type TextPage {
  TextPage(
    offset: Int,
    limit: Int,
    position: Int,
    pending: String,
    kept: List(String),
    more: Bool,
    first: Bool,
  )
}

/// Render a chronological source range without retaining its complete text.
/// Carry the final grapheme across fragments, since a trailing CR combines
/// with the next row's newline separator.
pub fn source_page(
  ledger: store.Store,
  snapshot: conversation.Snapshot,
  first: Int,
  last: Int,
  label: String,
  offset: Int,
  limit: Int,
) -> Result(#(String, Int, Bool), String) {
  let initial =
    TextPage(offset, int.clamp(limit, 1, 8000), 0, "", [], False, True)
  use page <- result.try(
    conversation.fold_sources(
      ledger,
      snapshot,
      first,
      last,
      initial,
      fn(page, item) {
        let separator = case page.first {
          True -> ""
          False -> "\n\n"
        }
        let text =
          separator
          <> "["
          <> label
          <> " #"
          <> int.to_string(item.source.seq)
          <> "]\n"
          <> row_text(item.entry.input)
        let page = consume(TextPage(..page, first: False), page.pending <> text)
        case page.more {
          True -> conversation.Stop(page)
          False -> conversation.Continue(page)
        }
      },
    ),
  )
  let page = case page.pending {
    "" -> page
    pending -> keep_grapheme(page, pending)
  }
  let content = page.kept |> list.reverse |> string.concat
  // nolint: albedo_text_scalars -- Page offsets count graphemes.
  Ok(#(content, offset + string.length(content), page.more))
}

fn consume(page: TextPage, text: String) -> TextPage {
  case string.pop_grapheme(text) {
    Error(_) -> TextPage(..page, pending: "")
    Ok(#(grapheme, "")) -> TextPage(..page, pending: grapheme)
    Ok(#(grapheme, rest)) -> {
      let page = keep_grapheme(page, grapheme)
      case page.more {
        True -> TextPage(..page, pending: "")
        False -> consume(page, rest)
      }
    }
  }
}

fn keep_grapheme(page: TextPage, grapheme: String) -> TextPage {
  case page.position < page.offset {
    True -> TextPage(..page, position: page.position + 1)
    False ->
      case page.position - page.offset < page.limit {
        True ->
          TextPage(..page, position: page.position + 1, kept: [
            grapheme,
            ..page.kept
          ])
        False -> TextPage(..page, more: True)
      }
  }
}
