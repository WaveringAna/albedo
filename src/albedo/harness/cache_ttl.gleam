//// The prompt-cache TTL table: the prior phase 2's cache-warmth estimate
//// runs on until a session's provider requests have measured the real thing.
////
//// Three layers merge by id — the shipped `priv/cache-ttl.json`, an optional
//// remote copy configured in extensions.json, and a local override in
//// `$ALBEDO_HOME` — with later layers replacing same-id entries in place and
//// putting new ids first, so an override can shadow a general default while
//// specific defaults keep their place. First match in table order wins a
//// lookup; values marked `folklore` or `unknown` are placeholders the ledger
//// replaces with measurements. The file I/O and revision cache live in
//// `albedo_cache_ttl.erl`; this module owns the shapes and the matching.

import albedo/harness/settings
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

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
/// placeholders phase 2 replaces with ledger measurements.
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

/// The remote layer's configuration in extensions.json: absent `url` means
/// no fetch, `refreshHours: 0` disables the background refresh.
pub type Config {
  Config(url: Option(String), refresh_hours: Int)
}

const remote_file = "cache-ttl-remote.json"

/// The merged table: all layers, entries tagged with where they came from.
/// Triggers a background refresh of a stale remote copy, like the models
/// catalog's lookups do.
pub fn table() -> Table {
  refresh()
  case native_merged() {
    Ok(encoded) ->
      json.parse(encoded, table_decoder()) |> result.unwrap(Table([], []))
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

/// Fetch and replace the remote copy now, regardless of its age, so an
/// explicit `/reload` never claims stale data was refreshed. A failed fetch
/// keeps the previous copy; no configured url is nothing to do.
pub fn reload() -> Result(Nil, String) {
  case settings.load("cacheTtl", config_decoder(), Config(None, 24)) {
    Ok(Config(url: None, ..)) -> Ok(Nil)
    Ok(Config(url: Some(url), ..)) -> native_reload(remote_path(), url)
    Error(reason) -> Error(reason)
  }
}

fn refresh() -> Nil {
  case settings.load("cacheTtl", config_decoder(), Config(None, 24)) {
    Ok(Config(url: Some(url), refresh_hours: hours)) ->
      case hours > 0 {
        True -> native_refresh(remote_path(), url, hours * 3_600_000)
        False -> Nil
      }
    _ -> Nil
  }
}

pub fn remote_path() -> String {
  settings.home() <> "/" <> remote_file
}

fn config_decoder() -> decode.Decoder(Config) {
  use url <- decode.optional_field("url", None, decode.optional(decode.string))
  use hours <- decode.optional_field("refreshHours", 24, decode.int)
  decode.success(Config(url, hours))
}

/// A bad entry never fails the table: it is skipped, and the reason logged.
fn table_decoder() -> decode.Decoder(Table) {
  use entries <- decode.field("entries", entries_decoder())
  use layers <- decode.field("layers", decode.list(layer_decoder()))
  decode.success(Table(entries, layers))
}

fn entries_decoder() -> decode.Decoder(List(Entry)) {
  decode.map(decode.list(decode.dynamic), fn(raw) {
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
    |> list.filter_map(fn(decoded) { decoded })
  })
}

fn layer_decoder() -> decode.Decoder(Layer) {
  use name <- decode.field("name", decode.string)
  use path <- decode.field("path", decode.string)
  use loaded <- decode.field("loaded", decode.bool)
  use error <- decode.optional_field(
    "error",
    None,
    decode.optional(decode.string),
  )
  decode.success(Layer(name, path, loaded, error))
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

fn matches_glob(pattern: String, value: String) -> Bool {
  glob(string.lowercase(pattern), string.lowercase(value))
}

/// Glob matching where `*` covers any run of characters, including none.
fn glob(pattern: String, value: String) -> Bool {
  case string.pop_grapheme(pattern) {
    Error(Nil) -> value == ""
    Ok(#("*", rest)) ->
      glob(rest, value)
      || case string.pop_grapheme(value) {
        Ok(#(_, tail)) -> glob(pattern, tail)
        Error(Nil) -> False
      }
    Ok(#(head, rest)) ->
      case string.pop_grapheme(value) {
        Ok(#(letter, tail)) -> head == letter && glob(rest, tail)
        Error(Nil) -> False
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

@external(erlang, "albedo_cache_ttl", "merged")
fn native_merged() -> Result(String, String)

@external(erlang, "albedo_cache_ttl", "refresh")
fn native_refresh(path: String, url: String, max_age_ms: Int) -> Nil

@external(erlang, "albedo_cache_ttl", "reload")
fn native_reload(path: String, url: String) -> Result(Nil, String)
