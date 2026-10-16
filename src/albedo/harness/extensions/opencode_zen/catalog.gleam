//// OpenCode Zen catalog: live `/models` discovery, so the free tier's
//// `-free` ids the gateway adds and retires appear without an albedo
//// release, with models.dev's `opencode` namespace filling in the context
//// limits, modalities, and reasoning tiers a bare id cannot carry.

import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import albedo/harness/settings
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// The gateway root. It serves both the catalog and inference, and is the
/// endpoint OpenCode's own free-tier requests go to.
pub const default_base_url = "https://opencode.ai/zen/v1"

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(
    lookup,
    list_models,
    Some(fn() { reload(settings.home()) }),
  )
}

fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  use <- bool.guard(!is_endpoint(at), None)

  let home = settings.home()
  let target_endpoint = option.unwrap(at, default_base_url)
  case models.lookup_provider("opencode", id) {
    Some(found) ->
      Some(
        extension.ModelInfo(
          ..found,
          model: id,
          provider: "opencode-zen",
          endpoint: Some(target_endpoint),
          environment: ["OPENCODE_ZEN_API_KEY", "OPENCODE_API_KEY"],
          source: "OpenCode Zen catalog, limits from " <> found.source,
        ),
      )
    None -> {
      // Not a model models.dev knows: answer only for one the gateway
      // actually lists, rather than inventing an entry for any id.
      let cached_ids = cached_models(home) |> result.unwrap([])
      use <- bool.guard(!list.contains(cached_ids, id), None)
      Some(models.complete_model(
        extension.ModelInfo(
          ..extension.blank_model(id, "opencode-zen"),
          endpoint: Some(target_endpoint),
          environment: ["OPENCODE_ZEN_API_KEY", "OPENCODE_API_KEY"],
          source: "OpenCode Zen catalog",
        ),
        Some(target_endpoint),
      ))
    }
  }
}

/// Whether `at` names the OpenCode gateway, so this catalog answers only for
/// an OpenCode endpoint and not for the same model id elsewhere.
fn is_endpoint(at: Option(String)) -> Bool {
  case at {
    None -> True
    Some(url) -> {
      let trimmed = string.remove_suffix(string.lowercase(url), "/")
      string.contains(trimmed, "opencode.ai/zen")
      || string.contains(trimmed, "opencode.ai/inference/openai")
      || string.contains(trimmed, "opencode-zen")
    }
  }
}

fn list_models(provider: String, endpoint: Option(String)) -> List(String) {
  case provider {
    "opencode-zen" ->
      case models(settings.home(), option.unwrap(endpoint, default_base_url)) {
        Ok([_, ..] as ids) -> ids
        _ -> cached_models(settings.home()) |> result.unwrap([])
      }
    _ -> []
  }
}

@external(erlang, "albedo_opencode_zen", "models")
fn models(home: String, endpoint: String) -> Result(List(String), String)

@external(erlang, "albedo_opencode_zen", "cached_models")
fn cached_models(home: String) -> Result(List(String), String)

@external(erlang, "albedo_opencode_zen", "reload")
fn reload(home: String) -> Result(Nil, String)
