//// Alibaba Model Studio catalog: model context limits, modalities, reasoning effort,
//// and live /models entitlement discovery.

import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import albedo/harness/settings
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const default_base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(
    lookup,
    list_models,
    Some(fn() { reload(settings.home()) }),
  )
}

fn lookup(id: String, at: String) -> Option(extension.ModelInfo) {
  let is_ali_endpoint =
    at == ""
    || string.contains(at, "aliyuncs.com")
    || string.contains(at, "dashscope")
    || string.contains(at, "alibaba")
    || string.remove_suffix(at, "/") == default_base_url
  use <- bool.guard(!is_ali_endpoint, None)

  let lower = string.lowercase(id)
  let home = settings.home()
  let cached_ids = models(home, at) |> result.unwrap([])
  let is_cached = list.contains(cached_ids, id)
  let is_ali_pattern =
    string.starts_with(lower, "qwen")
    || string.starts_with(lower, "deepseek-")
    || string.starts_with(lower, "glm-")
  use <- bool.guard(!is_cached && !is_ali_pattern, None)

  let target_endpoint = case at {
    "" -> default_base_url
    url -> url
  }
  let base =
    extension.ModelInfo(
      ..extension.blank_model(id, "alibaba"),
      endpoint: Some(target_endpoint),
      environment: ["ALIBABA_API_KEY", "DASHSCOPE_API_KEY"],
      source: "Alibaba Model Studio catalog",
    )
  Some(models.complete_model(base, target_endpoint))
}

fn list_models(provider: String, endpoint: String) -> List(String) {
  case provider {
    "alibaba" -> models(settings.home(), endpoint) |> result.unwrap([])
    _ -> []
  }
}

@external(erlang, "albedo_alibaba", "models")
pub fn models(home: String, endpoint: String) -> Result(List(String), String)

@external(erlang, "albedo_alibaba", "reload")
fn reload(home: String) -> Result(Nil, String)
