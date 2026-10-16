//// OpenCode Go catalog: model context limits, modalities, reasoning effort,
//// and live /models entitlement discovery.

import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import albedo/harness/settings
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const default_base_url = "https://opencode.ai/inference/go/v1"

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(
    lookup,
    list_models,
    Some(fn() { reload(settings.home()) }),
  )
}

fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  let is_opencode_go_endpoint = case at {
    None -> True
    Some(url) -> is_endpoint(url)
  }
  use <- bool.guard(!is_opencode_go_endpoint, None)

  let home = settings.home()
  let target_endpoint = option.unwrap(at, default_base_url)
  let base =
    extension.ModelInfo(
      ..extension.blank_model(id, "opencode-go"),
      endpoint: Some(target_endpoint),
      environment: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"],
      source: "OpenCode Go catalog",
    )
  case models.lookup_provider("opencode-go", id) {
    Some(found) -> {
      use <- bool.guard(
        at == None
          && models.lookup_provider("anthropic", id) != None
          && result.is_error(cached_models(home)),
        None,
      )
      Some(
        extension.ModelInfo(
          ..found,
          provider: "opencode-go",
          endpoint: Some(target_endpoint),
          environment: ["OPENCODE_GO_API_KEY", "OPENCODE_API_KEY"],
        ),
      )
    }
    None -> {
      let cached_ids =
        cached_models(home)
        |> result.unwrap([])
      use <- bool.guard(!list.contains(cached_ids, id), None)
      Some(models.complete_model(base, Some(target_endpoint)))
    }
  }
}

fn is_endpoint(url: String) -> Bool {
  let trimmed = string.remove_suffix(string.lowercase(url), "/")
  trimmed == default_base_url
  || trimmed == "https://opencode.ai/zen/go/v1"
  || string.contains(trimmed, "opencode.ai/inference/go")
  || string.contains(trimmed, "opencode.ai/zen/go")
  || string.contains(trimmed, "opencode-go")
}

fn list_models(provider: String, endpoint: Option(String)) -> List(String) {
  case provider {
    "opencode-go" ->
      case models(settings.home(), option.unwrap(endpoint, "")) {
        Ok([_, ..] as ids) -> ids
        _ -> models.list("opencode-go", None)
      }
    _ -> []
  }
}

@external(erlang, "albedo_opencode_go", "models")
fn models(home: String, endpoint: String) -> Result(List(String), String)

@external(erlang, "albedo_opencode_go", "cached_models")
fn cached_models(home: String) -> Result(List(String), String)

@external(erlang, "albedo_opencode_go", "reload")
fn reload(home: String) -> Result(Nil, String)
