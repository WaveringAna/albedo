//// Web search through a Claude sign-in: Claude answers the query with its
//// server-side `web_search` tool, and the pages it cites and searched become
//// the sources.

import albedo/harness/extensions/claude/wire
import albedo/harness/web_search
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// What the stream has said so far; lists newest first.
type Heard {
  Heard(
    searched: Bool,
    text: List(String),
    cited: List(web_search.Source),
    found: List(web_search.Source),
  )
}

/// `query` answered by `model` under `auth`. An answer given without
/// searching is refused: it would be Claude's memory passed off as a search
/// result.
pub fn run(
  home: String,
  auth: wire.Auth,
  model: String,
  query: web_search.Query,
) -> Result(web_search.Answer, String) {
  let request =
    types.Request(
      ..openai_api.request(model, [types.User(query.text)]),
      instructions: Some(web_search.instructions),
      max_output_tokens: Some(4096),
    )
  let tool =
    json.object([
      #("type", json.string("web_search_20250305")),
      #("name", json.string("web_search")),
      #("max_uses", json.int(5)),
    ])
  use exchange <- result.try(
    wire.encode_with(home, auth, request, [tool])
    |> result.map_error(web_search.failure),
  )
  use heard <- result.try(web_search.listen(
    exchange,
    Heard(False, [], [], []),
    hear,
  ))
  use <- bool.guard(
    !heard.searched,
    Error("Claude answered without searching the web"),
  )
  // What the answer cites leads; what the search turned up follows.
  let sources =
    list.append(list.reverse(heard.cited), list.reverse(heard.found))
  Ok(web_search.Answer(
    heard.text |> list.reverse |> string.concat |> string.trim,
    web_search.distinct(sources, query.limit),
  ))
}

fn hear(heard: Heard, data: String) -> Result(#(Heard, Bool), types.Error) {
  let kind =
    json.parse(data, decode.at(["type"], decode.string)) |> result.unwrap("")
  case kind {
    "error" ->
      Error(types.ProviderError(
        json.parse(data, decode.at(["error", "message"], decode.string))
        |> result.unwrap("Anthropic stream error"),
      ))
    "content_block_start" ->
      case json.parse(data, decode.at(["content_block"], block_decoder())) {
        Ok(Searching) -> Ok(#(Heard(..heard, searched: True), False))
        Ok(Results(found)) ->
          Ok(#(Heard(..heard, found: list.append(found, heard.found)), False))
        Ok(Spoken(text)) ->
          Ok(#(Heard(..heard, text: [text, ..heard.text]), False))
        Ok(Silent) | Error(_) -> Ok(#(heard, False))
      }
    "content_block_delta" ->
      case json.parse(data, decode.at(["delta"], delta_decoder())) {
        Ok(Said(text)) ->
          Ok(#(Heard(..heard, text: [text, ..heard.text]), False))
        Ok(Cited(source)) ->
          Ok(#(Heard(..heard, cited: [source, ..heard.cited]), False))
        Ok(Nothing) | Error(_) -> Ok(#(heard, False))
      }
    "message_stop" -> Ok(#(heard, True))
    _ -> Ok(#(heard, False))
  }
}

type Block {
  Searching
  Results(found: List(web_search.Source))
  Spoken(text: String)
  Silent
}

fn block_decoder() -> decode.Decoder(Block) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "server_tool_use" -> decode.success(Searching)
    "web_search_tool_result" -> {
      // An error result is an object, not a list: it found nothing.
      use found <- decode.optional_field(
        "content",
        [],
        decode.one_of(decode.list(result_decoder()), [decode.success([])]),
      )
      decode.success(Results(found |> option.values |> list.reverse))
    }
    "text" -> {
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(Spoken(text))
    }
    _ -> decode.success(Silent)
  }
}

fn result_decoder() -> decode.Decoder(Option(web_search.Source)) {
  use url <- decode.optional_field("url", "", decode.string)
  use title <- decode.optional_field("title", url, decode.string)
  use age <- decode.optional_field(
    "page_age",
    None,
    decode.optional(decode.string),
  )
  case url {
    "" -> decode.success(None)
    url -> decode.success(Some(web_search.Source(title, url, "", age)))
  }
}

type Delta {
  Said(text: String)
  Cited(source: web_search.Source)
  Nothing
}

fn delta_decoder() -> decode.Decoder(Delta) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "text_delta" -> {
      use text <- decode.field("text", decode.string)
      decode.success(Said(text))
    }
    "citations_delta" -> {
      use url <- decode.subfield(["citation", "url"], decode.string)
      use title <- decode.optional_field(
        "citation",
        url,
        decode.optional_field("title", url, decode.string, decode.success),
      )
      use quoted <- decode.optional_field(
        "citation",
        "",
        decode.optional_field("cited_text", "", decode.string, decode.success),
      )
      decode.success(Cited(web_search.Source(title, url, quoted, None)))
    }
    _ -> decode.success(Nothing)
  }
}
