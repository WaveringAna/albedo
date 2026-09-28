//// Codex model facts as the ChatGPT backend reports them for each signed-in
//// account: which models it offers, their windows, input kinds, and efforts.
//// Nothing here names a model, so a model OpenAI releases to Codex appears as
//// soon as the backend lists it.

import albedo/harness/extension
import gleam/dict
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

@external(erlang, "albedo_codex_models", "refresh")
fn native_refresh(
  home: String,
  access: String,
  account: String,
  max_age_ms: Int,
  now: Int,
) -> Result(Nil, String)

@external(erlang, "albedo_codex_models", "refresh_async")
fn native_refresh_async(
  home: String,
  access: String,
  account: String,
  max_age_ms: Int,
  now: Int,
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
  native_refresh(home, access, account, max_age_ms, system_time(Millisecond))
}

/// Brings one account's list up to date without waiting.
pub fn refresh_later(home: String, access: String, account: String) -> Nil {
  native_refresh_async(
    home,
    access,
    account,
    max_age_ms,
    system_time(Millisecond),
  )
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
    efforts,
    visible,
    priority,
  ))
}
