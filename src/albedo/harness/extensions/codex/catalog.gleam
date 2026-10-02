//// Codex model facts as the ChatGPT backend reports them for each signed-in
//// account: which models it offers, their windows, input kinds, and efforts.
//// Nothing here names a model, so a model OpenAI releases to Codex appears as
//// soon as the backend lists it.

import albedo/harness/extension
import albedo/openai_api/types
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

/// A refreshed account list is reused this long before the next request.
const max_age_ms = 3_600_000

pub type Model {
  Model(
    slug: String,
    name: String,
    context: Option(Int),
    max_context: Option(Int),
    input: List(String),
    efforts: List(String),
    visible: Bool,
    priority: Int,
  )
}

type Cache {
  Cache(client_version: String, accounts: List(List(Model)))
}

pub type Response {
  Response(status: Int, headers: List(#(String, String)), body: BitArray)
}

@external(erlang, "albedo_codex_models", "get")
fn native_get(
  url: String,
  headers: List(#(String, String)),
) -> Result(Response, Nil)

@external(erlang, "albedo_codex_models", "write")
fn native_write(home: String, encoded: String) -> Result(Nil, String)

@external(erlang, "albedo_codex_models", "refresh_async")
fn native_refresh_async(
  account: String,
  job: fn() -> Result(Nil, String),
) -> Nil

@external(erlang, "albedo_codex_models", "read")
fn native_read(home: String) -> Result(BitArray, Nil)

@external(erlang, "os", "system_time")
fn system_time(unit: Millisecond) -> Int

type Millisecond {
  Millisecond
}

/// Brings one account's list up to date, waiting for the network.
pub fn refresh(
  home: String,
  access: String,
  account: String,
) -> Result(Nil, String) {
  refresh_at(
    home,
    access,
    account,
    max_age_ms,
    system_time(Millisecond),
    native_get,
  )
}

/// Refetches one account's list whatever its age, rechecking the claimed
/// client version too, waiting for the network.
pub fn reload(
  home: String,
  access: String,
  account: String,
) -> Result(Nil, String) {
  refresh_at(home, access, account, 0, system_time(Millisecond), native_get)
}

/// Brings one account's list up to date without waiting.
pub fn refresh_later(home: String, access: String, account: String) -> Nil {
  let now = system_time(Millisecond)
  native_refresh_async(account, fn() {
    refresh_at(home, access, account, max_age_ms, now, native_get)
  })
}

/// Every model the backend lists for any signed-in account, by its priority.
pub fn listed(home: String) -> List(String) {
  models(home)
  |> list.filter(fn(model) { model.visible })
  |> list.sort(fn(a, b) {
    order.break_tie(
      int.compare(a.priority, b.priority),
      string.compare(a.slug, b.slug),
    )
  })
  |> list.map(fn(model) { model.slug })
}

/// What the backend reports about one model, hidden ones included: a session
/// may already use a model the list no longer shows.
pub fn lookup(
  home: String,
  endpoint: String,
  model: String,
) -> Option(extension.ModelInfo) {
  use cached <- option.then(cache(home) |> option.from_result)
  use found <- option.then(
    cached.accounts
    |> list.flatten
    |> list.find(fn(item) { item.slug == model })
    |> option.from_result,
  )
  Some(
    extension.ModelInfo(
      ..extension.blank_model(found.slug, "codex"),
      context_tokens: found.context,
      max_context_tokens: case found.context, found.max_context {
        Some(context), Some(max) if max > context -> Some(max)
        None, Some(max) -> Some(max)
        _, _ -> None
      },
      input_modalities: found.input,
      endpoint: Some(endpoint),
      source: "Codex models endpoint for the signed-in ChatGPT accounts"
        <> case cached.client_version {
          "" -> ""
          version -> " (client " <> version <> ")"
        },
      efforts: found.efforts,
    ),
  )
}

/// Every account's models, the first account's first, each slug once.
fn models(home: String) -> List(Model) {
  case cache(home) {
    Ok(Cache(_, accounts)) -> unique_models(accounts)
    Error(_) -> []
  }
}

fn unique_models(accounts: List(List(Model))) -> List(Model) {
  list.fold(list.flatten(accounts), #([], []), fn(state, model) {
    case list.contains(state.1, model.slug) {
      True -> state
      False -> #([model, ..state.0], [model.slug, ..state.1])
    }
  }).0
  |> list.reverse
}

fn cache(home: String) -> Result(Cache, Nil) {
  use bytes <- result.try(native_read(home))
  json.parse_bits(bytes, cache_decoder()) |> result.replace_error(Nil)
}

fn cache_decoder() -> decode.Decoder(Cache) {
  use version <- decode.optional_field("clientVersion", "", decode.string)
  use accounts <- decode.optional_field(
    "accounts",
    [],
    decode.dict(decode.string, {
      use models <- decode.optional_field(
        "models",
        [],
        decode.list(model_decoder()),
      )
      decode.success(models)
    })
      |> decode.map(dict.values),
  )
  decode.success(Cache(version, accounts))
}

fn model_decoder() -> decode.Decoder(Model) {
  use slug <- decode.field("slug", decode.string)
  use name <- decode.optional_field("name", slug, decode.string)
  use context <- decode.optional_field(
    "context",
    None,
    decode.optional(decode.int),
  )
  use max_context <- decode.optional_field(
    "maxContext",
    None,
    decode.optional(decode.int),
  )
  use input <- decode.optional_field("input", [], decode.list(decode.string))
  use efforts <- decode.optional_field(
    "efforts",
    [],
    decode.list(decode.string),
  )
  use visible <- decode.optional_field("visible", True, decode.bool)
  use priority <- decode.optional_field("priority", 1_000_000, decode.int)
  decode.success(Model(
    slug,
    name,
    context,
    max_context,
    input,
    usable_efforts(efforts),
    visible,
    priority,
  ))
}

/// The backend advertises "ultra" as a virtual tier, not a requestable effort.
fn usable_efforts(efforts: List(String)) -> List(String) {
  list.filter(efforts, fn(effort) { effort != "ultra" })
}

const models_url = "https://chatgpt.com/backend-api/codex/models"

const version_url = "https://registry.npmjs.org/@openai/codex/latest"

const fallback_version = "0.157.1"

const version_max_age_ms = 86_400_000

/// Refresh with a supplied clock and transport; storage is the real cache file.
/// Untouched account payloads remain opaque, unlike presentation decoding.
pub fn refresh_at(
  home: String,
  access: String,
  account: String,
  max_age_ms: Int,
  now: Int,
  get: fn(String, List(#(String, String))) -> Result(Response, Nil),
) -> Result(Nil, String) {
  let cached = case native_read(home) {
    Ok(bytes) ->
      json.parse_bits(bytes, decode.dict(decode.string, decode.dynamic))
      |> result.unwrap(dict.new())
    Error(_) -> dict.new()
  }
  use accounts <- result.try(case dict.get(cached, "accounts") {
    Ok(raw) ->
      decode.run(raw, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error("Codex model list could not be refreshed")
    Error(_) -> Ok(dict.new())
  })
  use entry <- result.try(case dict.get(accounts, account) {
    Ok(raw) ->
      decode.run(raw, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error("Codex model list could not be refreshed")
    Error(_) -> Ok(dict.new())
  })
  use _ <- result.try(validate_metadata(cached, entry))
  let #(version, updated) = check_version(cached, max_age_ms, now, get)
  let fresh =
    now - value(entry, "fetchedAt", decode.int, 0) < max_age_ms
    && value(entry, "clientVersion", decode.string, "") == version
  case fresh {
    True -> Ok(Nil)
    False -> {
      use etag <- result.try(
        case value(entry, "clientVersion", decode.string, "") == version {
          True ->
            case dict.get(entry, "etag") {
              Error(_) -> Ok("")
              Ok(raw) ->
                decode.run(raw, decode.string)
                |> result.replace_error(
                  "Codex model list could not be refreshed",
                )
            }
          False -> Ok("")
        },
      )
      let headers = [
        #("authorization", "Bearer " <> access),
        #("chatgpt-account-id", account),
        #("originator", "albedo"),
        #("version", version),
        #("accept", "application/json"),
      ]
      let headers = case etag {
        "" -> headers
        _ -> list.append(headers, [#("if-none-match", etag)])
      }
      case
        fetch_models(
          get(models_url <> "?client_version=" <> version, headers),
          entry,
        )
      {
        Ok(selected) -> {
          let selected =
            selected
            |> dict.insert("fetchedAt", json.int(now))
            |> dict.insert("clientVersion", json.string(version))
          let accounts =
            encode_fields(accounts)
            |> dict.insert(account, encode_object(selected))
          updated
          |> dict.insert("accounts", encode_object(accounts))
          |> save(home, _)
        }
        Error(reason) -> {
          let _ = save(home, updated)
          Error(reason)
        }
      }
    }
  }
}

fn value(
  fields: dict.Dict(String, Dynamic),
  key: String,
  decoder: decode.Decoder(a),
  default: a,
) -> a {
  dict.get(fields, key)
  |> result.try(fn(raw) {
    decode.run(raw, decoder) |> result.replace_error(Nil)
  })
  |> result.unwrap(default)
}

fn encode_fields(
  fields: dict.Dict(String, Dynamic),
) -> dict.Dict(String, json.Json) {
  dict.map_values(fields, fn(_, raw) { types.encode_value(raw) })
}

fn encode_object(fields: dict.Dict(String, json.Json)) -> json.Json {
  json.object(dict.to_list(fields))
}

fn save(
  home: String,
  fields: dict.Dict(String, json.Json),
) -> Result(Nil, String) {
  native_write(home, json.to_string(encode_object(fields)))
}

fn check_version(
  cached: dict.Dict(String, Dynamic),
  max_age_ms: Int,
  now: Int,
  get: fn(String, List(#(String, String))) -> Result(Response, Nil),
) -> #(String, dict.Dict(String, json.Json)) {
  let version = value(cached, "clientVersion", decode.string, "")
  let checked = value(cached, "versionCheckedAt", decode.int, 0)
  let encoded = encode_fields(cached)
  case
    version != "" && now - checked < int.min(max_age_ms, version_max_age_ms)
  {
    True -> #(version, encoded)
    False -> {
      let fetched = case get(version_url, [#("accept", "application/json")]) {
        Ok(Response(200, _, body)) ->
          json.parse_bits(body, {
            use version <- decode.field("version", decode.string)
            decode.success(version)
          })
          |> result.replace_error(Nil)
        _ -> Error(Nil)
      }
      case fetched {
        Ok(new_version) ->
          case valid_version(new_version) {
            True -> #(
              new_version,
              encoded
                |> dict.insert("clientVersion", json.string(new_version))
                |> dict.insert("versionCheckedAt", json.int(now)),
            )
            False -> #(
              case version {
                "" -> fallback_version
                _ -> version
              },
              encoded,
            )
          }
        Error(_) -> #(
          case version {
            "" -> fallback_version
            _ -> version
          },
          encoded,
        )
      }
    }
  }
}

fn valid_version(version: String) -> Bool {
  let parts = string.split(version, ".")
  list.length(parts) == 3
  && list.all(parts, fn(part) {
    part != ""
    && list.all(string.to_graphemes(part), fn(char) {
      list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], char)
    })
  })
}

fn fetch_models(
  response: Result(Response, Nil),
  entry: dict.Dict(String, Dynamic),
) -> Result(dict.Dict(String, json.Json), String) {
  case response {
    Ok(Response(304, _, _)) -> Ok(encode_fields(entry))
    Ok(Response(200, headers, body)) -> {
      use rows <- result.try(
        json.parse_bits(body, {
          use rows <- decode.field("models", decode.list(decode.dynamic))
          decode.success(rows)
        })
        |> result.replace_error("Codex model list is not valid"),
      )
      let etag =
        headers
        |> list.find(fn(header) { header.0 == "etag" })
        |> result.map(fn(header) { header.1 })
        |> result.unwrap("")
      Ok(
        dict.from_list([
          #("etag", json.string(etag)),
          #("models", json.array(normalize(rows), encode_model)),
        ]),
      )
    }
    Ok(Response(status, _, _)) ->
      Error("Codex model list returned HTTP " <> int.to_string(status))
    Error(_) -> Error("Codex model list request failed")
  }
}

/// Accept valid identities while treating optional upstream facts independently.
pub fn normalize(rows: List(Dynamic)) -> List(Model) {
  list.filter_map(rows, fn(raw) {
    use fields <- result.try(
      decode.run(raw, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error(Nil),
    )
    let slug = value(fields, "slug", decode.string, "")
    case slug {
      "" -> Error(Nil)
      _ -> {
        let name = value(fields, "display_name", decode.string, slug)
        let input =
          value(fields, "input_modalities", decode.list(decode.dynamic), [])
          |> list.filter_map(fn(raw) { decode.run(raw, decode.string) })
        let efforts =
          value(
            fields,
            "supported_reasoning_levels",
            decode.list(decode.dynamic),
            [],
          )
          |> list.filter_map(fn(raw) {
            decode.run(raw, {
              use effort <- decode.field("effort", decode.string)
              decode.success(effort)
            })
          })
        Ok(Model(
          slug,
          case name {
            "" -> slug
            _ -> name
          },
          positive(value(fields, "context_window", decode.int, 0)),
          positive(value(fields, "max_context_window", decode.int, 0)),
          input,
          usable_efforts(efforts),
          case dict.get(fields, "visibility") {
            Error(_) -> True
            Ok(raw) -> decode.run(raw, decode.string) == Ok("list")
          },
          value(fields, "priority", decode.int, 1_000_000),
        ))
      }
    }
  })
}

fn positive(value: Int) -> Option(Int) {
  case value > 0 {
    True -> Some(value)
    False -> None
  }
}

fn encode_model(model: Model) -> json.Json {
  json.object([
    #("slug", json.string(model.slug)),
    #("name", json.string(model.name)),
    #("context", json.nullable(model.context, json.int)),
    #("maxContext", json.nullable(model.max_context, json.int)),
    #("input", json.array(model.input, json.string)),
    #("efforts", json.array(model.efforts, json.string)),
    #("visible", json.bool(model.visible)),
    #("priority", json.int(model.priority)),
  ])
}

fn validate_metadata(
  cached: dict.Dict(String, Dynamic),
  entry: dict.Dict(String, Dynamic),
) -> Result(Nil, String) {
  let checks = [
    #(cached, "clientVersion", decode.string |> decode.map(fn(_) { Nil })),
    #(cached, "versionCheckedAt", decode.int |> decode.map(fn(_) { Nil })),
    #(entry, "clientVersion", decode.string |> decode.map(fn(_) { Nil })),
    #(entry, "fetchedAt", decode.int |> decode.map(fn(_) { Nil })),
  ]
  list.try_each(checks, fn(check) {
    case dict.get(check.0, check.1) {
      Error(_) -> Ok(Nil)
      Ok(raw) ->
        decode.run(raw, check.2)
        |> result.replace_error("Codex model list could not be refreshed")
    }
  })
}
