//// Default context-window caps by provider extension, host, and model glob.
////
//// Two layers merge by id — the shipped `priv/context-limits.json` and a local
//// override in `$ALBEDO_HOME/context-limits.json` — with the local layer
//// replacing same-id entries in place and putting new ids first. First match in
//// table order wins a lookup. When a matched entry specifies a smaller
//// `contextTokens` than the catalog's window, the catalog's window becomes
//// `max_context_tokens` so `/raise-cap` and the model picker can still raise
//// the cap to the provider's ceiling.

import albedo/harness/cache_ttl
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Entry {
  Entry(
    id: String,
    layer: String,
    match: cache_ttl.Match,
    context_tokens: Int,
    note: String,
  )
}

pub type Layer {
  Layer(name: String, path: String, loaded: Bool, error: Option(String))
}

pub type Table {
  Table(entries: List(Entry), layers: List(Layer))
}

pub fn table() -> Table {
  case native_table() {
    Ok(table) -> table
    Error(reason) -> {
      io.println_error("context-limits: " <> reason)
      Table([], [])
    }
  }
}

pub fn lookup(extension: String, host: String, model: String) -> Option(Entry) {
  table().entries
  |> list.find(fn(entry) { matches(entry, extension, host, model) })
  |> option.from_result
}

pub fn lookup_endpoint(
  extension: String,
  endpoint: Option(String),
  model: String,
) -> Option(Entry) {
  let host =
    option.then(endpoint, fn(url) {
      uri.parse(url)
      |> result.map(fn(parsed) { parsed.host })
      |> result.unwrap(None)
    })
    |> option.unwrap("")
  lookup(extension, host, model)
}

pub fn validate_layer(
  raw: Dynamic,
) -> Result(List(Dict(String, Dynamic)), String) {
  cache_ttl.validate_layer(raw)
  |> result.map_error(string.replace(_, "cache-ttl", "context-limits"))
}

pub fn decode_table(raw: List(Dynamic), reports: List(Layer)) -> Table {
  let entries =
    raw
    |> list.index_map(fn(item, position) {
      case decode.run(item, entry_decoder()) {
        Ok(entry) -> Ok(entry)
        Error(errors) -> {
          report(position, errors)
          Error(Nil)
        }
      }
    })
    |> list.filter_map(fn(entry) { entry })
  Table(entries, reports)
}

fn entry_decoder() -> decode.Decoder(Entry) {
  use id <- decode.field("id", decode.string)
  use layer <- decode.field("layer", decode.string)
  use match <- decode.optional_field(
    "match",
    cache_ttl.Match(None, None, None),
    match_decoder(),
  )
  use context_tokens <- decode.field("contextTokens", positive_tokens())
  use note <- decode.optional_field("note", "", decode.string)
  decode.success(Entry(id, layer, match, context_tokens, note))
}

fn match_decoder() -> decode.Decoder(cache_ttl.Match) {
  use extension <- decode.optional_field("extension", None, globs_decoder())
  use host <- decode.optional_field("host", None, globs_decoder())
  use model <- decode.optional_field("model", None, globs_decoder())
  decode.success(cache_ttl.Match(extension, host, model))
}

fn globs_decoder() -> decode.Decoder(Option(List(String))) {
  decode.one_of(decode.optional(decode.list(decode.string)), or: [
    decode.map(decode.optional(decode.string), fn(one) {
      option.map(one, fn(pattern) { [pattern] })
    }),
  ])
}

fn positive_tokens() -> decode.Decoder(Int) {
  decode.int
  |> decode.then(fn(value) {
    case is_window(value) {
      True -> decode.success(value)
      False -> decode.failure(0, "a positive token count")
    }
  })
}

fn matches(
  entry: Entry,
  extension: String,
  host: String,
  model: String,
) -> Bool {
  let cache_ttl.Match(extensions, hosts, models) = entry.match
  covers(extensions, extension) && covers(hosts, host) && covers(models, model)
}

fn covers(patterns: Option(List(String)), value: String) -> Bool {
  case patterns {
    None -> True
    Some(patterns) ->
      list.any(patterns, fn(pattern) { cache_ttl.matches_glob(pattern, value) })
  }
}

fn report(position: Int, errors: List(decode.DecodeError)) -> Nil {
  let reasons =
    list.map(errors, fn(error) {
      let where = case error.path {
        [] -> "the entry"
        path -> string.join(path, ".")
      }
      where <> " (expected " <> error.expected <> ")"
    })
    |> string.join(", ")
  io.println_error(
    "context-limits: skipping entry "
    <> int.to_string(position)
    <> ": "
    <> reasons,
  )
}

/// The largest context window, in tokens, that a session or an entry may name.
const max_window = 100_000_000

/// Whether `tokens` is a window the daemon accepts.
pub fn is_window(tokens: Int) -> Bool {
  tokens > 0 && tokens <= max_window
}

/// Parses a human token count such as `100k`, `1.5m`, or `150000` (with
/// optional underscores or commas).
pub fn parse_tokens(raw: String) -> Result(Int, String) {
  let cleaned =
    raw
    |> string.trim
    |> string.lowercase
    |> string.replace("_", "")
    |> string.replace(",", "")
  let #(number, multiplier) = case
    string.ends_with(cleaned, "k"),
    string.ends_with(cleaned, "m")
  {
    True, _ -> #(string.drop_end(cleaned, 1), 1000)
    _, True -> #(string.drop_end(cleaned, 1), 1_000_000)
    _, _ -> #(cleaned, 1)
  }
  use tokens <- result.try(case string.split_once(number, ".") {
    Error(_) ->
      int.parse(number)
      |> result.map(fn(whole) { whole * multiplier })
      |> result.replace_error(invalid_tokens(raw))
    Ok(#(whole_part, frac_part)) ->
      case multiplier > 1 && whole_part != "" && frac_part != "" {
        False -> Error(invalid_tokens(raw))
        True -> {
          use whole <- result.try(
            int.parse(whole_part) |> result.replace_error(invalid_tokens(raw)),
          )
          use frac <- result.try(
            int.parse(frac_part) |> result.replace_error(invalid_tokens(raw)),
          )
          let scale = ten_pow(string.length(frac_part))
          case whole >= 0 && frac >= 0 && scale <= multiplier {
            True -> Ok(whole * multiplier + frac * { multiplier / scale })
            False -> Error(invalid_tokens(raw))
          }
        }
      }
  })
  case is_window(tokens) {
    True -> Ok(tokens)
    False -> Error(invalid_tokens(raw))
  }
}

fn ten_pow(exp: Int) -> Int {
  case exp <= 0 {
    True -> 1
    False -> 10 * ten_pow(exp - 1)
  }
}

fn invalid_tokens(raw: String) -> String {
  "expected a positive token count (such as 100k, 250000, or 1m) or default, not "
  <> raw
}

@external(erlang, "albedo_context_limits", "table")
fn native_table() -> Result(Table, String)
