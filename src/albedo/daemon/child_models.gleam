//// Which provider profile and model a new child or peer runs on.
////
//// Listing a profile's models can ask its endpoint over the network (the
//// generic openai extension reads `<endpoint>/models`), so callers resolve a
//// choice in their own process before they ask the registry: the registry
//// answers every request in the daemon, and an endpoint that never answers
//// once held it for seconds per spawn, failing every request meanwhile.

import albedo/daemon/configuration
import albedo/daemon/conversation
import albedo/daemon/session_provider
import albedo/harness/runtime
import albedo/text_scalars
import gleam/list
import gleam/result
import gleam/string

/// A profile and the model to run on it, or why there is none.
pub type Choice =
  Result(#(configuration.Provider, String), String)

/// `requested` is "provider/model", a bare model, or "" for the parent's. A
/// bare model stays on the parent's provider when it lists it, and otherwise
/// moves to the one other provider that does. Only the profiles a decision
/// needs are listed.
pub fn resolve(
  host: runtime.Runtime,
  home: String,
  parent: conversation.Info,
  requested: String,
) -> Choice {
  use profiles <- result.try(configuration.providers(home))
  let qualified =
    list.find_map(profiles, fn(profile) {
      let prefix = profile.name <> "/"
      case string.starts_with(requested, prefix) {
        True ->
          Ok(#(
            profile,
            text_scalars.drop(requested, text_scalars.length(prefix)),
          ))
        False -> Error(Nil)
      }
    })
  case qualified {
    Ok(#(profile, model)) ->
      case list.contains(listed(host, home, profile), model) {
        True -> Ok(#(profile, model))
        False -> Error("model is not available from provider " <> profile.name)
      }
    Error(_) -> {
      use current <- result.try(configuration.named(home, parent.provider))
      let model = case requested {
        "" -> parent.model
        _ -> requested
      }
      case list.contains(listed(host, home, current), model) {
        True -> Ok(#(current, model))
        False ->
          case
            list.filter(profiles, fn(profile) {
              profile.name != current.name
              && list.contains(listed(host, home, profile), model)
            })
          {
            [profile] -> Ok(#(profile, model))
            [] -> Ok(#(current, model))
            _ ->
              Error(
                "model is available from multiple providers; use provider/model",
              )
          }
      }
    }
  }
}

/// What a session may hand a child: its own model and its provider's models
/// bare, then every other provider's as "provider/model".
pub fn available(
  host: runtime.Runtime,
  home: String,
  info: conversation.Info,
) -> List(String) {
  let profiles = configuration.providers(home) |> result.unwrap([])
  let #(same, other) =
    list.partition(profiles, fn(profile) { profile.name == info.provider })
  let same_models = list.flat_map(same, listed(host, home, _))
  let other_models =
    list.flat_map(other, fn(profile) {
      listed(host, home, profile)
      |> list.map(fn(model) { profile.name <> "/" <> model })
    })
  list.unique([info.model, ..list.append(same_models, other_models)])
}

fn listed(
  host: runtime.Runtime,
  home: String,
  provider: configuration.Provider,
) -> List(String) {
  // A generic extension (openai) serves many gateways; the profile's endpoint
  // names which catalog provider's models it lists.
  let endpoint = session_provider.profile_endpoint(home, provider.name)
  list.unique([
    provider.model,
    ..runtime.model_names(host, provider.extension, endpoint)
  ])
}
