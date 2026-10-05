//// Exa's search API as a web search provider. The key lives in creds.json
//// under `exa.apiKey`; extensions.json may point `exa.endpoint` at another
//// host.

import albedo/harness/extension
import albedo/harness/settings
import albedo/harness/web_search
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/result
import gleam/string

const default_endpoint = "https://api.exa.ai"

pub fn extension() -> extension.Extension {
  extension.Extension(
    "exa",
    "Exa web search with an API key from creds.json",
    [],
    [extension.SearchPlugin(web_search.Provider("exa", "Exa", search))],
    extension.no_initialise,
  )
}

fn search(query: web_search.Query) -> Result(web_search.Answer, String) {
  let home = settings.home()
  use key <- result.try(api_key(home))
  use endpoint <- result.try(settings.load(
    "exa",
    decode.optional_field(
      "endpoint",
      default_endpoint,
      decode.string,
      decode.success,
    ),
    default_endpoint,
  ))
  let body =
    json.object([
      #("query", json.string(query.text)),
      #("numResults", json.int(query.limit)),
      #("type", json.string("auto")),
      #(
        "contents",
        json.object([
          #(
            "highlights",
            json.object([
              #("numSentences", json.int(3)),
              #("highlightsPerUrl", json.int(2)),
            ]),
          ),
        ]),
      ),
    ])
  use #(status, _, reply) <- result.try(
    post(
      string.remove_suffix(endpoint, "/") <> "/search",
      [#("x-api-key", key), #("accept", "application/json")],
      "application/json",
      json.to_string(body),
      60_000,
      10_000,
    )
    |> result.replace_error("Exa could not be reached"),
  )
  let reply = bit_array.to_string(reply) |> result.unwrap("")
  case status {
    200 ->
      json.parse(reply, decode.at(["results"], decode.list(result_decoder())))
      |> result.replace_error("Exa answered with an unreadable result list")
      |> result.map(fn(sources) {
        web_search.Answer("", web_search.distinct(sources, query.limit))
      })
    401 | 403 -> Error("Exa refused the API key in creds.json")
    _ ->
      Error(
        "Exa answered HTTP "
        <> int.to_string(status)
        <> ": "
        <> string.slice(string.trim(reply), 0, 300),
      )
  }
}

/// The key under `exa.apiKey` in creds.json.
fn api_key(home: String) -> Result(String, String) {
  let missing = "Exa needs an API key: set exa.apiKey in creds.json"
  use saved <- result.try(
    read_credentials(home <> "/creds.json") |> result.replace_error(missing),
  )
  case decode.run(saved, decode.at(["exa", "apiKey"], decode.string)) {
    Ok(key) if key != "" -> Ok(key)
    _ -> Error(missing)
  }
}

fn result_decoder() -> decode.Decoder(web_search.Source) {
  use url <- decode.field("url", decode.string)
  use title <- decode.optional_field(
    "title",
    url,
    decode.optional(decode.string) |> decode.map(option.unwrap(_, url)),
  )
  use highlights <- decode.optional_field(
    "highlights",
    [],
    decode.optional(decode.list(decode.string))
      |> decode.map(option.unwrap(_, [])),
  )
  use published <- decode.optional_field(
    "publishedDate",
    None,
    decode.optional(decode.string),
  )
  decode.success(web_search.Source(
    title,
    url,
    highlights |> list.map(string.trim) |> string.join(" … "),
    published,
  ))
}

@external(erlang, "albedo_credentials", "read")
fn read_credentials(path: String) -> Result(Dynamic, Dynamic)

@external(erlang, "albedo_http", "post")
fn post(
  url: String,
  headers: List(#(String, String)),
  content_type: String,
  body: String,
  timeout_ms: Int,
  connect_ms: Int,
) -> Result(#(Int, Dynamic, BitArray), Dynamic)
