//// Selection policy over the native catalog's reduced, revision-cached index.

import albedo/harness/extension
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// These tuples are the persisted index ABI. Decode untrusted scalar metadata
// before returning an answer; do not copy or re-encode the whole catalog.
pub type IndexedModel =
  // Id, context limit, output limit, input modalities, reasoning efforts.
  #(String, Dynamic, Dynamic, List(String), List(String))

pub type Provider =
  // Host, API URL, environment variables, sorted model ids.
  #(String, Dynamic, List(String), List(String))

pub type Candidate =
  #(String, IndexedModel)

pub type LookupError {
  MissingModel
  Unavailable(reason: String)
}

pub fn select(
  candidates: List(Candidate),
  providers: Dict(String, Provider),
  host: String,
) -> Result(extension.ModelInfo, LookupError) {
  let matched = case host {
    "" -> Error(Nil)
    "chatgpt.com" -> list.find(candidates, fn(entry) { entry.0 == "openai" })
    _ ->
      list.find(candidates, fn(entry) {
        // A candidate's provider must exist in the same cached index.
        let assert Ok(provider) = dict.get(providers, entry.0)
        provider.0 == host
      })
  }
  case matched {
    Ok(entry) ->
      attributed(entry, providers, case host {
        "chatgpt.com" -> "provider identity"
        _ -> "provider endpoint"
      })
    Error(_) -> unattributed(candidates)
  }
}

pub fn select_provider(
  candidates: List(Candidate),
  providers: Dict(String, Provider),
  provider: String,
) -> Result(extension.ModelInfo, LookupError) {
  use entry <- result.try(
    list.find(candidates, fn(entry) { entry.0 == provider })
    |> result.replace_error(MissingModel),
  )
  attributed(entry, providers, "provider name")
}

fn attributed(
  entry: Candidate,
  providers: Dict(String, Provider),
  matched: String,
) -> Result(extension.ModelInfo, LookupError) {
  use provider <- result.try(
    dict.get(providers, entry.0)
    |> result.replace_error(Unavailable("models catalog lookup failed")),
  )
  use api <- result.try(
    decode.run(provider.1, decode.optional(decode.string))
    |> result.replace_error(Unavailable(
      "models catalog provider API is invalid",
    )),
  )
  let model = entry.1
  Ok(
    extension.ModelInfo(
      ..extension.blank_model(model.0, entry.0),
      context_tokens: positive_limit(model.1),
      max_output_tokens: positive_limit(model.2),
      input_modalities: model.3,
      endpoint: api,
      environment: provider.2,
      source: matched,
      efforts: model.4,
    ),
  )
}

fn unattributed(
  candidates: List(Candidate),
) -> Result(extension.ModelInfo, LookupError) {
  let models = sorted(candidates) |> list.map(fn(entry) { entry.1 })
  case models {
    [] -> Error(MissingModel)
    [first, ..] -> {
      let limits = list.map(models, fn(model) { #(model.1, model.2) })
      let matched = case unique(limits) {
        [_] -> "model id"
        _ ->
          "model id; smallest limits of "
          <> int.to_string(list.length(models))
          <> " providers"
      }
      Ok(
        extension.ModelInfo(
          ..extension.blank_model(first.0, ""),
          context_tokens: smallest(list.map(models, fn(model) { model.1 })),
          max_output_tokens: smallest(list.map(models, fn(model) { model.2 })),
          input_modalities: shared(list.map(models, fn(model) { model.3 })),
          source: matched,
          efforts: shared(list.map(models, fn(model) { model.4 })),
        ),
      )
    }
  }
}

fn positive_limit(value: Dynamic) -> Option(Int) {
  case decode.run(value, decode.int) {
    Ok(limit) if limit > 0 -> Some(limit)
    _ -> None
  }
}

fn smallest(values: List(Dynamic)) -> Option(Int) {
  list.fold(values, None, fn(smallest, value) {
    case smallest, positive_limit(value) {
      None, known -> known
      Some(current), Some(known) -> Some(int.min(current, known))
      _, None -> smallest
    }
  })
}

// Empty lists mean unknown, so only candidates reporting capabilities constrain
// the intersection. Keep the first reporting candidate's order and duplicates.
fn shared(lists: List(List(String))) -> List(String) {
  case list.filter(lists, fn(items) { items != [] }) {
    [] -> []
    [first, ..rest] ->
      list.filter(first, fn(item) {
        list.all(rest, fn(items) { list.contains(items, item) })
      })
  }
}

pub fn list_provider(
  providers: Dict(String, Provider),
  provider: String,
  host: String,
) -> Result(List(String), String) {
  let selected = case host {
    "" -> dict.get(providers, provider)
    _ ->
      dict.values(providers)
      |> list.find(fn(metadata) { metadata.0 == host })
      |> result.lazy_or(fn() { dict.get(providers, provider) })
  }
  selected
  |> result.map(fn(metadata) { metadata.3 })
  |> result.replace_error("provider is not in the cached catalog")
}

// Preserve native tuple ordering, including duplicate aliases from one provider,
// and numeric equality in the index's raw limit pairs.
@external(erlang, "lists", "sort")
fn sorted(values: List(a)) -> List(a)

@external(erlang, "lists", "usort")
fn unique(values: List(a)) -> List(a)
