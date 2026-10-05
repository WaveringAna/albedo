//// Web search as a provider extension answers it, under that extension's own
//// sign-in. The `web-search` extension ranks the providers and falls
//// through them in the user's order.

import albedo/harness/settings
import albedo/openai_api
import albedo/openai_api/stream
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/set
import gleam/string

/// What a model that searches is asked to do with the query.
pub const instructions = "Search the web to answer the question. Answer directly first, then the evidence: exact versions, dates, figures, and names, from primary sources where they exist. Say when sources disagree or the answer is uncertain. Cite every claim inline with its link."

pub type Query {
  Query(
    text: String,
    /// The most sources the answer should carry.
    limit: Int,
    /// The asking session, for providers that keep an account per session.
    session: String,
  )
}

pub type Source {
  Source(title: String, url: String, snippet: String, published: Option(String))
}

/// Grounded prose, empty from a plain search engine, and the pages behind it.
pub type Answer {
  Answer(text: String, sources: List(Source))
}

pub type Provider {
  Provider(
    /// The key the user's order names it by.
    name: String,
    label: String,
    search: fn(Query) -> Result(Answer, String),
  )
}

/// The model `searchModel` names in `extension`'s section of
/// extensions.json, when it names one.
pub fn configured_model(extension: String) -> Option(String) {
  let configured =
    settings.load(
      extension,
      decode.optional_field("searchModel", "", decode.string, decode.success),
      "",
    )
  case configured {
    Ok("") | Error(_) -> None
    Ok(model) -> Some(model)
  }
}

/// Why a provider's HTTP exchange failed, short enough to list beside the
/// other providers' reasons.
pub fn failure(error: types.Error) -> String {
  case error {
    types.HttpError(status, body) ->
      "HTTP "
      <> int.to_string(status)
      <> ": "
      <> {
        json.parse(body, decode.at(["error", "message"], decode.string))
        |> result.unwrap(body)
        |> string.trim
        |> string.slice(0, 300)
      }
    types.InvalidRequest(message)
    | types.ConnectionError(message)
    | types.InvalidEvent(message)
    | types.ProviderError(message)
    | types.Unsupported(message) -> message
    types.Timeout -> "timed out"
    types.Cancelled -> "cancelled"
    types.EventTooLarge -> "a streamed event was too large"
    types.UnexpectedEnd -> "the stream ended before the answer did"
  }
}

/// The state `hear` folds `exchange`'s streamed payloads into, from
/// `initial`, as the stream left it. `hear` answers True once the answer is
/// complete; a stream that simply ends is complete too.
pub fn listen(
  exchange: openai_api.Exchange,
  initial: state,
  hear: fn(state, String) -> Result(#(state, Bool), types.Error),
) -> Result(state, String) {
  // The reducer runs in this process, so its last state comes back as a
  // message rather than through the turn, which has no room for it.
  let heard = process.new_subject()
  let done = fn(state) {
    process.send(heard, state)
    Ok(types.Turn(None, [], [], None, types.Complete, None, []))
  }
  let reducer =
    stream.wrap(
      initial,
      fn(state, data) {
        use #(state, complete) <- result.try(hear(state, data))
        case complete {
          True ->
            done(state) |> result.map(fn(turn) { #(state, [], Some(turn)) })
          False -> Ok(#(state, [], None))
        }
      },
      done,
    )
  use _ <- result.try(
    openai_api.exchange(exchange, reducer, fn(_) { types.Continue })
    |> result.map_error(failure),
  )
  process.receive(heard, 0)
  |> result.replace_error("the stream ended without an answer")
}

/// `sources` without a second source for any url, first one kept, cut to
/// `limit`.
pub fn distinct(sources: List(Source), limit: Int) -> List(Source) {
  sources
  |> list.fold(#([], set.new()), fn(kept, source) {
    let #(sources, seen) = kept
    case set.contains(seen, source.url) {
      True -> kept
      False -> #([source, ..sources], set.insert(seen, source.url))
    }
  })
  |> pair.first
  |> list.reverse
  |> list.take(limit)
}
