//// Web search through a ChatGPT sign-in: a Codex model answers the query
//// with its hosted `web_search` tool, and the pages it cites and searched
//// become the sources.

import albedo/harness/web_search
import albedo/openai_api
import albedo/openai_api/stream
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// What one output item of the response contributes.
type Item {
  Searched(found: List(web_search.Source))
  Said(text: String, cited: List(web_search.Source))
  Other
}

/// `query` answered by `model` through `client`. An answer given without
/// searching is refused: it would be the model's memory passed off as a
/// search result.
pub fn run(
  client: types.Client,
  model: String,
  query: web_search.Query,
) -> Result(web_search.Answer, String) {
  let exchange =
    openai_api.Exchange(
      url: string.remove_suffix(client.base_url, "/") <> "/codex/responses",
      headers: openai_api.headers(client, model),
      body: json.to_string_tree(body(model, query.text)),
      // A search can go quiet for a while between its last result and the
      // first words of the answer.
      timeout_ms: 120_000,
      max_event_bytes: client.max_event_bytes,
      require_event_stream: False,
    )
  use turn <- result.try(
    openai_api.exchange(exchange, stream.reducer(types.Responses), fn(_) {
      types.Continue
    })
    |> result.map_error(web_search.failure),
  )
  let items =
    list.filter_map(turn.output, fn(item) {
      types.inspect_item(item, item_decoder()) |> result.replace_error(Nil)
    })
  let searched =
    list.any(items, fn(item) {
      case item {
        Searched(_) -> True
        _ -> False
      }
    })
  use <- bool.guard(
    !searched,
    Error("ChatGPT answered without searching the web"),
  )
  let said =
    list.filter_map(items, fn(item) {
      case item {
        Said(text, cited) -> Ok(#(text, cited))
        _ -> Error(Nil)
      }
    })
  let found =
    list.flat_map(items, fn(item) {
      case item {
        Searched(found) -> found
        _ -> []
      }
    })
  let text = said |> list.map(fn(part) { part.0 }) |> string.join("\n\n")
  // What the answer cites leads; what the search turned up follows.
  let sources = list.append(list.flat_map(said, fn(part) { part.1 }), found)
  Ok(web_search.Answer(
    string.trim(text),
    web_search.distinct(sources, query.limit),
  ))
}

fn body(model: String, text: String) -> json.Json {
  json.object([
    #("model", json.string(model)),
    #("instructions", json.string(web_search.instructions)),
    #(
      "input",
      json.preprocessed_array([
        json.object([
          #("type", json.string("message")),
          #("role", json.string("user")),
          #(
            "content",
            json.preprocessed_array([
              json.object([
                #("type", json.string("input_text")),
                #("text", json.string(text)),
              ]),
            ]),
          ),
        ]),
      ]),
    ),
    #(
      "tools",
      json.preprocessed_array([
        json.object([#("type", json.string("web_search"))]),
      ]),
    ),
    #("tool_choice", json.object([#("type", json.string("web_search"))])),
    #(
      "include",
      json.preprocessed_array([json.string("web_search_call.action.sources")]),
    ),
    #("reasoning", json.object([#("effort", json.string("low"))])),
    #("store", json.bool(False)),
    #("stream", json.bool(True)),
  ])
}

fn item_decoder() -> decode.Decoder(Item) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "web_search_call" -> {
      use found <- decode.optional_field(
        "action",
        None,
        decode.optional(nullable_list("sources", found_decoder())),
      )
      decode.success(Searched(option.values(option.unwrap(found, []))))
    }
    "message" -> {
      use parts <- decode.optional_field(
        "content",
        [],
        decode.list(part_decoder()),
      )
      let parts = option.values(parts)
      decode.success(Said(
        parts |> list.map(fn(part) { part.0 }) |> string.join(""),
        list.flat_map(parts, fn(part) { part.1 }),
      ))
    }
    _ -> decode.success(Other)
  }
}

/// The list under `name`, empty when it is missing or null.
fn nullable_list(
  name: String,
  inner: decode.Decoder(a),
) -> decode.Decoder(List(a)) {
  use values <- decode.optional_field(
    name,
    None,
    decode.optional(decode.list(inner)),
  )
  decode.success(option.unwrap(values, []))
}

/// A page the search turned up; `None` for one without a url.
fn found_decoder() -> decode.Decoder(Option(web_search.Source)) {
  use url <- decode.optional_field("url", "", decode.string)
  use title <- decode.optional_field("title", url, decode.string)
  case url {
    "" -> decode.success(None)
    url -> decode.success(Some(web_search.Source(title, clean(url), "", None)))
  }
}

/// An output_text part's text and the pages it cites; `None` for any other
/// part.
fn part_decoder() -> decode.Decoder(Option(#(String, List(web_search.Source)))) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "output_text" -> {
      use text <- decode.optional_field("text", "", decode.string)
      use cited <- decode.then(nullable_list("annotations", citation_decoder()))
      decode.success(Some(#(text, option.values(cited))))
    }
    _ -> decode.success(None)
  }
}

fn citation_decoder() -> decode.Decoder(Option(web_search.Source)) {
  use kind <- decode.field("type", decode.string)
  use url <- decode.optional_field("url", "", decode.string)
  use title <- decode.optional_field("title", url, decode.string)
  case kind, url {
    "url_citation", url if url != "" ->
      decode.success(Some(web_search.Source(title, clean(url), "", None)))
    _, _ -> decode.success(None)
  }
}

/// The url without the `utm_source=openai` ChatGPT tags its links with.
fn clean(url: String) -> String {
  url
  |> string.replace("?utm_source=openai&", "?")
  |> string.replace("&utm_source=openai", "")
  |> string.replace("?utm_source=openai", "")
}
