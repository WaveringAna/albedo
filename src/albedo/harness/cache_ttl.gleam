//// The prompt-cache TTL table supplies an initial cache-warmth estimate
//// until the session's provider requests supply measurements.
////
//// Three layers merge by id — the shipped `priv/cache-ttl.json`, an optional
//// remote copy configured in extensions.json, and a local override in
//// `$ALBEDO_HOME` — with later layers replacing same-id entries in place and
//// putting new ids first, so an override can shadow a general default while
//// specific defaults keep their place. First match in table order wins a
//// lookup; values marked `folklore` or `unknown` are placeholders the ledger
//// replaces with measurements. The file I/O and revision cache live in
//// `albedo_cache_ttl.erl`; this module owns merging, shapes, and matching.

import albedo/daemon/configuration
import albedo/harness/settings
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// Whether a lifetime is restarted by every hit, counted from the write, or
/// left to the provider's eviction with no clock at all.
pub type Policy {
  Refresh
  Fixed
  Evict
  Unknown
}

/// Whether a lifetime counts from request start or response end.
pub type Clock {
  Request
  Response
}

/// How well the numbers are known. `Folklore` and `Unverified` are
/// placeholders the ledger replaces with measurements.
pub type Evidence {
  Documented
  Measured
  Implemented
  Folklore
  Unverified
}

/// One TTL a request can ask for, with the price of the write that buys it.
pub type Tier {
  Tier(seconds: Int, write: Option(Float))
}

/// Best-effort eviction windows: typical survival, and a bound when known.
pub type Survival {
  Survival(typical: Int, max: Option(Int))
}

/// Which requests an entry describes. An absent field matches anything; a
/// pattern matches case-insensitively, with `*` for any run of characters.
pub type Match {
  Match(
    extension: Option(List(String)),
    host: Option(List(String)),
    model: Option(List(String)),
  )
}

pub type Entry {
  Entry(
    id: String,
    /// The layer the entry came from: default, remote, or local.
    layer: String,
    match: Match,
    policy: Policy,
    clock: Clock,
    tiers: Option(List(Tier)),
    /// The read-price multiplier, when the provider charges for hits.
    read: Option(Float),
    survival: Option(Survival),
    evidence: Evidence,
    source: String,
    checked: String,
    note: String,
  )
}

/// One layer of the merged table, as the route reports it.
pub type Layer {
  Layer(name: String, path: String, loaded: Bool, error: Option(String))
}

pub type Table {
  Table(entries: List(Entry), layers: List(Layer))
}

/// Merge native layer entries in precedence order. The file reader has checked
/// their ids; other fields stay raw until the merged table is decoded, so an
/// invalid override still shadows the entry it replaces.
pub fn merge_layers(
  layers: List(#(String, List(Dict(String, Dynamic)))),
) -> List(Dict(String, Dynamic)) {
  list.fold(layers, [], fn(entries, layer) {
    let tagged =
      list.map(layer.1, fn(fields) {
        let assert Ok(value) = dict.get(fields, "id")
        let assert Ok(id) = decode.run(value, decode.string)
        #(id, dict.insert(fields, "layer", dynamic.string(layer.0)))
      })
    case entries, tagged {
      [], _ -> tagged
      _, [] -> entries
      _, _ -> {
        // Unmatched ids stay indexed so every new entry keeps its original order.
        let #(unmatched, replaced) =
          list.map_fold(
            entries,
            dict.from_list(tagged),
            fn(replacements, entry) {
              let #(id, _) = entry
              case dict.get(replacements, id) {
                Ok(fields) -> #(dict.delete(replacements, id), #(id, fields))
                Error(_) -> #(replacements, entry)
              }
            },
          )
        let fresh =
          list.filter(tagged, fn(entry) { dict.has_key(unmatched, entry.0) })
        list.append(fresh, replaced)
      }
    }
  })
  |> list.map(fn(entry) { entry.1 })
}

/// The remote layer's configuration in extensions.json: `url: null` disables
/// fetching; `refreshHours: 0` disables the background refresh.
type Config {
  Config(url: Option(String), refresh_hours: Int)
}

const remote_file = "cache-ttl-remote.json"

const default_url =
  "https://api.next.tangled.org/xrpc/org.tangled.temp.git.getBlob?repo=did%3Aplc%3Al7hhzcbqqvpcquau5waryzdu&ref=main&path=priv%2Fcache-ttl.json"

const defaults = Config(Some(default_url), 24)

/// The merged table: all layers, entries tagged with where they came from.
/// Triggers a background refresh of a stale remote copy, like the models
/// catalog's lookups do.
pub fn table() -> Table {
  refresh()
  case native_table() {
    Ok(table) -> table
    Error(reason) -> {
      io.println_error("cache-ttl: " <> reason)
      Table([], [])
    }
  }
}

/// The first entry in table order whose match covers the request. The file
/// lists specific entries before general ones, so order is the precedence.
pub fn lookup(extension: String, host: String, model: String) -> Option(Entry) {
  table().entries
  |> list.find(fn(entry) { matches(entry, extension, host, model) })
  |> option.from_result
}

/// The entry for a call sent through a saved profile: matched on the
/// provider extension the profile resolves to, the endpoint's host, and the
/// model.
pub fn for_call(
  profile: String,
  endpoint: String,
  model: String,
) -> Option(Entry) {
  let extension = case configuration.named(settings.home(), profile) {
    Ok(configured) -> configured.extension
    Error(_) -> ""
  }
  let host = case uri.parse(endpoint) {
    Ok(uri.Uri(host: Some(host), ..)) -> host
    _ -> ""
  }
  lookup(extension, host, model)
}

/// Whether the entry's lifetime counts from the send's start rather than
/// its finish; with no entry, from the finish.
pub fn from_start(entry: Option(Entry)) -> Bool {
  case entry {
    Some(entry) -> entry.clock == Request
    None -> False
  }
}

/// The lifetime of a prefix the provider caches on its own, when it has a
/// clock at all: the first tier, while the policy is one every hit restarts
/// or one counted from the write. Best-effort eviction has no clock.
pub fn clock_tier(entry: Entry) -> Option(Tier) {
  case entry.policy, entry.tiers {
    Refresh, Some([tier, ..]) | Fixed, Some([tier, ..]) -> Some(tier)
    _, _ -> None
  }
}

/// Fetch and replace the remote copy now, regardless of its age, so an
/// explicit `/reload` never claims stale data was refreshed. A failed fetch
/// keeps the previous copy; no configured url is nothing to do.
pub fn reload() -> Result(Nil, String) {
  case settings.load("cacheTtl", config_decoder(), defaults) {
    Ok(Config(url: None, ..)) -> Ok(Nil)
    Ok(Config(url: Some(url), ..)) -> native_reload(remote_path(), url)
    Error(reason) -> Error(reason)
  }
}

fn refresh() -> Nil {
  case settings.load("cacheTtl", config_decoder(), defaults) {
    Ok(Config(url: Some(url), refresh_hours: hours)) ->
      case hours > 0 {
        True -> native_refresh(remote_path(), url, hours * 3_600_000)
        False -> Nil
      }
    _ -> Nil
  }
}

fn remote_path() -> String {
  settings.home() <> "/" <> remote_file
}

fn config_decoder() -> decode.Decoder(Config) {
  use url <- decode.optional_field(
    "url",
    Some(default_url),
    decode.optional(decode.string),
  )
  use hours <- decode.optional_field("refreshHours", 24, decode.int)
  decode.success(Config(url, hours))
}

/// Check mergeable identities before decoding policies, preserving shadowing.
/// Duplicate ids make a layer ambiguous, so the previous revision stays active.
pub fn validate_layer(
  raw: Dynamic,
) -> Result(List(Dict(String, Dynamic)), String) {
  let decoder =
    decode.field("entries", decode.list(decode.dynamic), decode.success)
  use entries <- result.try(
    decode.run(raw, decoder)
    |> result.replace_error(
      "cache-ttl table is not an object with an entries list",
    ),
  )
  use checked <- result.try(
    list.try_fold(entries, #([], dict.new(), 0), fn(state, raw) {
      let fields_decoder = decode.dict(decode.string, decode.dynamic)
      case decode.run(raw, fields_decoder) {
        Error(_) -> {
          Ok(#(state.0, state.1, state.2 + 1))
        }
        Ok(fields) ->
          case
            dict.get(fields, "id")
            |> result.try(fn(value) {
              decode.run(value, decode.string) |> result.replace_error(Nil)
            })
          {
            Error(_) -> {
              Ok(#(state.0, state.1, state.2 + 1))
            }
            Ok(id) ->
              case dict.has_key(state.1, id) {
                True -> Error("cache-ttl table has duplicate id: " <> id)
                False ->
                  Ok(#(
                    [fields, ..state.0],
                    dict.insert(state.1, id, Nil),
                    state.2,
                  ))
              }
          }
      }
    }),
  )
  case checked.2 > 0 {
    True ->
      io.println_error(
        "cache-ttl: skipping "
        <> int.to_string(checked.2)
        <> " entries without a string id",
      )
    False -> Nil
  }
  Ok(list.reverse(checked.0))
}

/// Decode the merged revision once; invalid overrides have already shadowed
/// their earlier entries by id before semantic decoding skips them.
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
    Match(None, None, None),
    match_decoder(),
  )
  use policy <- decode.field("policy", policy_decoder())
  use clock <- decode.optional_field("clock", Response, clock_decoder())
  use tiers <- decode.optional_field(
    "tiers",
    None,
    decode.optional(tiers_decoder()),
  )
  use read <- decode.optional_field("read", None, decode.optional(multiplier()))
  use survival <- decode.optional_field(
    "survival",
    None,
    decode.optional(survival_decoder()),
  )
  use evidence <- decode.field("evidence", evidence_decoder())
  use source <- decode.optional_field("source", "", decode.string)
  use checked <- decode.optional_field("checked", "", decode.string)
  use note <- decode.optional_field("note", "", decode.string)
  decode.success(Entry(
    id,
    layer,
    match,
    policy,
    clock,
    tiers,
    read,
    survival,
    evidence,
    source,
    checked,
    note,
  ))
}

fn match_decoder() -> decode.Decoder(Match) {
  use extension <- decode.optional_field("extension", None, globs_decoder())
  use host <- decode.optional_field("host", None, globs_decoder())
  use model <- decode.optional_field("model", None, globs_decoder())
  decode.success(Match(extension, host, model))
}

/// One pattern or a list of them, where a list matches if any element does.
fn globs_decoder() -> decode.Decoder(Option(List(String))) {
  decode.one_of(decode.optional(decode.list(decode.string)), or: [
    decode.map(decode.optional(decode.string), fn(one) {
      option.map(one, fn(pattern) { [pattern] })
    }),
  ])
}

fn policy_decoder() -> decode.Decoder(Policy) {
  decode.string
  |> decode.then(fn(policy) {
    case policy {
      "refresh" -> decode.success(Refresh)
      "fixed" -> decode.success(Fixed)
      "evict" -> decode.success(Evict)
      "unknown" -> decode.success(Unknown)
      _ ->
        decode.failure(Unknown, "a policy of refresh, fixed, evict or unknown")
    }
  })
}

fn clock_decoder() -> decode.Decoder(Clock) {
  decode.string
  |> decode.then(fn(clock) {
    case clock {
      "request" -> decode.success(Request)
      "response" -> decode.success(Response)
      _ -> decode.failure(Response, "a clock of request or response")
    }
  })
}

fn evidence_decoder() -> decode.Decoder(Evidence) {
  decode.string
  |> decode.then(fn(evidence) {
    case evidence {
      "documented" -> decode.success(Documented)
      "measured" -> decode.success(Measured)
      "implemented" -> decode.success(Implemented)
      "folklore" -> decode.success(Folklore)
      "unknown" -> decode.success(Unverified)
      _ ->
        decode.failure(
          Unverified,
          "evidence of documented, measured, implemented, folklore or unknown",
        )
    }
  })
}

fn tiers_decoder() -> decode.Decoder(List(Tier)) {
  decode.list(tier_decoder())
}

fn tier_decoder() -> decode.Decoder(Tier) {
  use seconds <- decode.field(
    "seconds",
    positive_int("a positive number of seconds"),
  )
  use write <- decode.optional_field(
    "write",
    None,
    decode.optional(multiplier()),
  )
  decode.success(Tier(seconds, write))
}

fn survival_decoder() -> decode.Decoder(Survival) {
  use typical <- decode.field(
    "typical",
    positive_int("a positive number of seconds"),
  )
  use max <- decode.optional_field("max", None, decode.optional(decode.int))
  decode.success(Survival(typical, max))
}

fn multiplier() -> decode.Decoder(Float) {
  decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)])
  |> decode.then(fn(value) {
    case value >. 0.0 {
      True -> decode.success(value)
      False -> decode.failure(0.0, "a positive multiplier")
    }
  })
}

fn positive_int(expected: String) -> decode.Decoder(Int) {
  decode.int
  |> decode.then(fn(value) {
    case value > 0 {
      True -> decode.success(value)
      False -> decode.failure(0, expected)
    }
  })
}

/// Every named field of the match must cover the request.
fn matches(
  entry: Entry,
  extension: String,
  host: String,
  model: String,
) -> Bool {
  let Match(extensions, hosts, models) = entry.match
  covers(extensions, extension) && covers(hosts, host) && covers(models, model)
}

fn covers(patterns: Option(List(String)), value: String) -> Bool {
  case patterns {
    None -> True
    Some(patterns) ->
      list.any(patterns, fn(pattern) { matches_glob(pattern, value) })
  }
}

/// Case-insensitive Unicode grapheme matching; only `*` is special.
/// Remember the most recent wildcard and retry from its next value position.
/// Each retry scans at most the pattern, giving O(pattern × value) work.
pub fn matches_glob(pattern: String, value: String) -> Bool {
  glob(
    string.to_graphemes(string.lowercase(pattern)),
    string.to_graphemes(string.lowercase(value)),
    None,
  )
}

fn glob(
  pattern: List(String),
  value: List(String),
  wildcard: Option(#(List(String), List(String))),
) -> Bool {
  case pattern, value {
    [], [] -> True
    ["*", ..rest], _ -> glob(rest, value, Some(#(rest, value)))
    [head, ..rest], [letter, ..tail] if head == letter ->
      glob(rest, tail, wildcard)
    _, _ ->
      case wildcard {
        Some(#(rest, [_, ..tail])) -> glob(rest, tail, Some(#(rest, tail)))
        _ -> False
      }
  }
}

fn report(position: Int, errors: List(decode.DecodeError)) -> Nil {
  let reasons =
    list.map(errors, fn(error) {
      let where = case error.path {
        [] -> "the entry"
        path -> "the entry at " <> string.join(path, ".")
      }
      error.expected <> " (found " <> error.found <> ") at " <> where
    })
    |> string.join("; ")
  io.println_error(
    "cache-ttl: skipping entry " <> int.to_string(position) <> ": " <> reasons,
  )
}

pub fn table_json(table: Table) -> Json {
  json.object([
    #("entries", json.array(table.entries, entry_json)),
    #("layers", json.array(table.layers, layer_json)),
  ])
}

pub fn entry_json(entry: Entry) -> Json {
  json.object([
    #("id", json.string(entry.id)),
    #("layer", json.string(entry.layer)),
    #("match", match_json(entry.match)),
    #("policy", json.string(policy_name(entry.policy))),
    #("clock", json.string(clock_name(entry.clock))),
    #(
      "tiers",
      optional(entry.tiers, fn(tiers) { json.array(tiers, tier_json) }),
    ),
    #("read", optional(entry.read, json.float)),
    #("survival", optional(entry.survival, survival_json)),
    #("evidence", json.string(evidence_name(entry.evidence))),
    #("source", json.string(entry.source)),
    #("checked", json.string(entry.checked)),
    #("note", json.string(entry.note)),
  ])
}

fn layer_json(layer: Layer) -> Json {
  json.object([
    #("name", json.string(layer.name)),
    #("path", json.string(layer.path)),
    #("loaded", json.bool(layer.loaded)),
    #("error", optional(layer.error, json.string)),
  ])
}

fn match_json(match: Match) -> Json {
  let Match(extension, host, model) = match
  json.object([
    #(
      "extension",
      optional(extension, fn(patterns) { json.array(patterns, json.string) }),
    ),
    #(
      "host",
      optional(host, fn(patterns) { json.array(patterns, json.string) }),
    ),
    #(
      "model",
      optional(model, fn(patterns) { json.array(patterns, json.string) }),
    ),
  ])
}

fn tier_json(tier: Tier) -> Json {
  json.object([
    #("seconds", json.int(tier.seconds)),
    #("write", optional(tier.write, json.float)),
  ])
}

fn survival_json(survival: Survival) -> Json {
  json.object([
    #("typical", json.int(survival.typical)),
    #("max", optional(survival.max, json.int)),
  ])
}

fn optional(value: Option(a), encode: fn(a) -> Json) -> Json {
  case value {
    Some(present) -> encode(present)
    None -> json.null()
  }
}

fn policy_name(policy: Policy) -> String {
  case policy {
    Refresh -> "refresh"
    Fixed -> "fixed"
    Evict -> "evict"
    Unknown -> "unknown"
  }
}

fn clock_name(clock: Clock) -> String {
  case clock {
    Request -> "request"
    Response -> "response"
  }
}

fn evidence_name(evidence: Evidence) -> String {
  case evidence {
    Documented -> "documented"
    Measured -> "measured"
    Implemented -> "implemented"
    Folklore -> "folklore"
    Unverified -> "unknown"
  }
}

@external(erlang, "albedo_cache_ttl", "table")
fn native_table() -> Result(Table, String)

@external(erlang, "albedo_cache_ttl", "refresh")
fn native_refresh(path: String, url: String, max_age_ms: Int) -> Nil

@external(erlang, "albedo_cache_ttl", "reload")
fn native_reload(path: String, url: String) -> Result(Nil, String)
