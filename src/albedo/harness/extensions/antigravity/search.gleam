//// Web search through a Google Antigravity sign-in: Gemini answers the query
//// grounded in Google Search, and the pages it grounded on become the
//// sources.

import albedo/harness/extensions/antigravity/wire
import albedo/harness/web_search
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string

/// What the stream has said so far; lists newest first.
type Heard {
  Heard(text: List(String), found: List(web_search.Source), queries: Int)
}

/// One streamed chunk: its answer text and the grounding it reports.
type Chunk {
  Chunk(text: List(String), found: List(web_search.Source), queries: Int)
}

/// `query` answered by the model `context` names. An answer with no Google
/// Search grounding is refused: it would be Gemini's memory passed off as a
/// search result.
pub fn run(
  context: wire.Context,
  query: web_search.Query,
) -> Result(web_search.Answer, String) {
  let request =
    types.Request(
      ..openai_api.request(context.model.id, [types.User(query.text)]),
      instructions: Some(web_search.instructions),
    )
  let tool = json.object([#("googleSearch", json.object([]))])
  use exchange <- result.try(
    wire.encode_with(context, request, [tool])
    |> result.map_error(web_search.failure),
  )
  use heard <- result.try(
    web_search.listen(exchange, Heard([], [], 0), fn(heard, data) {
      let chunk =
        json.parse(data, chunk_decoder()) |> result.unwrap(Chunk([], [], 0))
      Ok(#(
        Heard(
          list.append(list.reverse(chunk.text), heard.text),
          list.append(list.reverse(chunk.found), heard.found),
          heard.queries + chunk.queries,
        ),
        False,
      ))
    }),
  )
  use <- bool.guard(
    heard.queries == 0 && heard.found == [],
    Error("Gemini answered without searching the web"),
  )
  let found = list.reverse(heard.found)
  // Grounding links are Google redirects titled with the bare domain; one
  // HEAD each, side by side, finds the page they stand for.
  let pages = locations(list.map(found, fn(source) { source.url }), 5000)
  let found =
    list.map2(found, pages, fn(source, page) {
      web_search.Source(..source, url: page)
    })
  // Gemini writes its own links into the prose, and some point at pages it
  // never grounded on; the sources are the pages it did.
  Ok(web_search.Answer(
    heard.text |> list.reverse |> string.concat |> unlink |> string.trim,
    web_search.distinct(found, query.limit),
  ))
}

/// `text` with each markdown link `[label](http…)` cut to its label; code
/// such as `f[T any](v T)` keeps its brackets.
pub fn unlink(text: String) -> String {
  case string.split_once(text, "](") {
    Error(_) -> text
    Ok(#(before, after)) ->
      case
        string.starts_with(after, "http"),
        past_url(after, 0),
        split_last(before, "[")
      {
        True, Ok(rest), Ok(#(lead, label)) -> lead <> label <> unlink(rest)
        _, _, _ -> before <> "](" <> unlink(after)
      }
  }
}

/// What follows the `)` that closes a link's url, counting the parentheses
/// the url itself opens: `a_(b)) more` -> ` more`.
fn past_url(text: String, depth: Int) -> Result(String, Nil) {
  case string.pop_grapheme(text) {
    Error(_) -> Error(Nil)
    Ok(#(")", rest)) if depth == 0 -> Ok(rest)
    Ok(#(")", rest)) -> past_url(rest, depth - 1)
    Ok(#("(", rest)) -> past_url(rest, depth + 1)
    Ok(#("\n", _)) -> Error(Nil)
    Ok(#(_, rest)) -> past_url(rest, depth)
  }
}

/// `text` split around the last `separator` in it.
fn split_last(
  text: String,
  separator: String,
) -> Result(#(String, String), Nil) {
  case string.split(text, separator) |> list.reverse {
    [last, second, ..rest] ->
      Ok(#([second, ..rest] |> list.reverse |> string.join(separator), last))
    _ -> Error(Nil)
  }
}

@external(erlang, "albedo_http", "locations")
fn locations(urls: List(String), timeout_ms: Int) -> List(String)

/// A Cloud Code chunk wraps Gemini's own response; thought parts are left
/// out of the answer.
fn chunk_decoder() -> decode.Decoder(Chunk) {
  let part = {
    use thought <- decode.optional_field("thought", False, decode.bool)
    use text <- decode.optional_field("text", "", decode.string)
    decode.success(case thought {
      True -> ""
      False -> text
    })
  }
  let found = {
    use url <- decode.optional_field("uri", "", decode.string)
    use title <- decode.optional_field("title", url, decode.string)
    decode.success(web_search.Source(title, url, "", None))
  }
  let candidate = {
    use parts <- decode.optional_field(
      "content",
      [],
      decode.optional_field("parts", [], decode.list(part), decode.success),
    )
    use grounding <- decode.optional_field("groundingMetadata", #([], 0), {
      use chunks <- decode.optional_field(
        "groundingChunks",
        [],
        decode.list(decode.optional_field(
          "web",
          None,
          decode.optional(found),
          decode.success,
        )),
      )
      use queries <- decode.optional_field(
        "webSearchQueries",
        [],
        decode.list(decode.string),
      )
      decode.success(#(option.values(chunks), list.length(queries)))
    })
    decode.success(Chunk(parts, grounding.0, grounding.1))
  }
  use candidates <- decode.subfield(
    ["response", "candidates"],
    decode.list(candidate),
  )
  case candidates {
    [first, ..] ->
      decode.success(
        Chunk(
          ..first,
          found: list.filter(first.found, fn(source) { source.url != "" }),
        ),
      )
    [] -> decode.success(Chunk([], [], 0))
  }
}
