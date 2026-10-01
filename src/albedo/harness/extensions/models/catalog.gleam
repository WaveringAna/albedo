//// Selection policy over the native catalog's reduced, revision-cached index.

import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// These tuples are the persisted index ABI. Decode untrusted scalar metadata
// before encoding an answer; do not copy or re-encode the whole catalog.
pub type IndexedModel =
  // Id, context limit, output limit, input modalities, reasoning efforts.
  #(String, Dynamic, Dynamic, List(String), List(String))

pub type Provider =
  // Host, API URL, environment variables, sorted model ids.
  #(String, Dynamic, List(String), List(String))

pub type Candidate =
  #(String, IndexedModel)

pub fn select(
  candidates: List(Candidate),
  providers: Dict(String, Provider),
  host: String,
) -> Result(Json, String) {
  let matched = case host {
    "chatgpt.com" -> list.find(candidates, fn(entry) { entry.0 == "openai" })
    _ ->
      list.find(candidates, fn(entry) {
        case host {
          "" -> False
          _ -> {
            // A candidate's provider must exist in the same cached index.
            let assert Ok(provider) = dict.get(providers, entry.0)
            provider.0 == host
          }
        }
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
) -> Result(Json, String) {
  use entry <- result.try(
    list.find(candidates, fn(entry) { entry.0 == provider })
    |> result.replace_error("model is not listed by this provider"),
  )
  attributed(entry, providers, "provider name")
}

fn attributed(
  entry: Candidate,
  providers: Dict(String, Provider),
  matched: String,
) -> Result(Json, String) {
  use provider <- result.try(
    dict.get(providers, entry.0)
    |> result.replace_error("models catalog lookup failed"),
  )
  let model = entry.1
  Ok(
    json.object([
      #("model", json.string(model.0)),
      #("provider", json.string(entry.0)),
      #("context", json.nullable(positive_limit(model.1), json.int)),
      #("output", json.nullable(positive_limit(model.2), json.int)),
      #("input_modalities", json.array(model.3, json.string)),
      #("api", types.encode_value(provider.1)),
      #("env", json.array(provider.2, json.string)),
      #("matched", json.string(matched)),
      #("efforts", json.array(model.4, json.string)),
    ]),
  )
}

fn unattributed(candidates: List(Candidate)) -> Result(Json, String) {
  let models = sorted(candidates) |> list.map(fn(entry) { entry.1 })
  case models {
    [] -> Error("model is not in the cached catalog")
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
        json.object([
          #("model", json.string(first.0)),
          #("provider", json.string("")),
          #(
            "context",
            json.nullable(
              smallest(list.map(models, fn(model) { model.1 })),
              json.int,
            ),
          ),
          #(
            "output",
            json.nullable(
              smallest(list.map(models, fn(model) { model.2 })),
              json.int,
            ),
          ),
          #(
            "input_modalities",
            json.array(
              shared(list.map(models, fn(model) { model.3 })),
              json.string,
            ),
          ),
          #("api", json.null()),
          #("env", json.array([], json.string)),
          #("matched", json.string(matched)),
          #(
            "efforts",
            json.array(
              shared(list.map(models, fn(model) { model.4 })),
              json.string,
            ),
          ),
        ]),
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
) -> Result(Json, String) {
  let matched =
    dict.values(providers)
    |> list.find(fn(metadata) { host != "" && metadata.0 == host })
  let selected = case matched {
    Ok(metadata) -> Ok(metadata)
    Error(_) -> dict.get(providers, provider)
  }
  selected
  |> result.map(fn(metadata) { json.array(metadata.3, json.string) })
  |> result.replace_error("provider is not in the cached catalog")
}

// Preserve native tuple ordering, including duplicate aliases from one provider,
// and numeric equality in the index's raw limit pairs.
@external(erlang, "lists", "sort")
fn sorted(values: List(a)) -> List(a)

@external(erlang, "lists", "usort")
fn unique(values: List(a)) -> List(a)
