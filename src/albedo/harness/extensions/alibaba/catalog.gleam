//// Alibaba Model Studio catalog: model context limits, modalities, reasoning effort,
//// and live /models entitlement discovery.

import albedo/harness/extension
import albedo/harness/settings
import gleam/bool
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub const default_base_url = "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"

pub type Model {
  Model(
    id: String,
    name: String,
    context_tokens: Int,
    max_output_tokens: Int,
    images: Bool,
    efforts: List(String),
  )
}

/// Known token plan models with verified capacities and reasoning tiers.
pub fn known() -> List(Model) {
  [
    Model(
      "deepseek-v4-flash-0731",
      "DeepSeek V4 Flash 0731",
      1_000_000,
      384_000,
      False,
      ["low", "medium", "high", "xhigh", "max"],
    ),
    Model("deepseek-v4-pro", "DeepSeek V4 Pro", 1_000_000, 384_000, False, [
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]),
    Model(
      "deepseek-v4.1-flash",
      "DeepSeek V4.1 Flash",
      1_000_000,
      384_000,
      True,
      ["low", "medium", "high", "xhigh", "max"],
    ),
    Model("glm-5.2", "GLM 5.2", 1_000_000, 131_072, False, [
      "low",
      "medium",
      "high",
      "xhigh",
      "max",
    ]),
    Model("glm-5.3", "GLM 5.3", 1_000_000, 131_072, False, [
      "low",
      "high",
      "max",
    ]),
    Model("qwen3.6-flash", "Qwen 3.6 Flash", 1_000_000, 65_536, True, []),
    Model("qwen3.7-max", "Qwen 3.7 Max", 1_000_000, 131_072, False, []),
    Model("qwen3.7-plus", "Qwen 3.7 Plus", 1_000_000, 65_536, True, []),
    Model("qwen3.8-flash", "Qwen 3.8 Flash", 1_000_000, 131_072, True, []),
    Model("qwen3.8-max", "Qwen 3.8 Max", 1_000_000, 131_072, True, []),
  ]
}

/// Fallback heuristic for newly released models discovered from the live endpoint.
pub fn hint(id: String) -> Model {
  case list.find(known(), fn(m) { m.id == id }) {
    Ok(m) -> m
    Error(_) -> {
      let lower = string.lowercase(id)
      let is_deepseek = string.starts_with(lower, "deepseek-")
      let is_glm = string.starts_with(lower, "glm-")
      let is_glm_5_3 = string.contains(lower, "5.3")
      let has_image =
        string.contains(lower, "-vl")
        || string.contains(lower, "flash")
        || string.contains(lower, "plus")
        || string.contains(lower, "max")
      let efforts = case is_deepseek {
        True -> ["low", "medium", "high", "xhigh", "max"]
        False ->
          case is_glm {
            True ->
              case is_glm_5_3 {
                True -> ["low", "high", "max"]
                False -> ["low", "medium", "high", "xhigh", "max"]
              }
            False -> []
          }
      }
      let output = case is_deepseek {
        True -> 384_000
        False ->
          case is_glm {
            True -> 131_072
            False -> 65_536
          }
      }
      Model(id, id, 1_000_000, output, has_image, efforts)
    }
  }
}

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(lookup, list_models)
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
  let is_known = list.any(known(), fn(m) { m.id == id })
  let is_ali_pattern =
    string.starts_with(lower, "qwen")
    || string.starts_with(lower, "deepseek-")
    || string.starts_with(lower, "glm-")
  case is_known || is_ali_pattern {
    False -> None
    True -> {
      let model = hint(id)
      Some(extension.ModelInfo(
        model.id,
        "alibaba",
        Some(model.context_tokens),
        Some(model.max_output_tokens),
        case model.images {
          True -> ["text", "image"]
          False -> ["text"]
        },
        Some(default_base_url),
        ["ALIBABA_API_KEY", "DASHSCOPE_API_KEY"],
        "Alibaba Model Studio catalog",
        model.efforts,
      ))
    }
  }
}

fn list_models(provider: String, endpoint: String) -> List(String) {
  case provider {
    "alibaba" -> {
      let home = settings.home()
      case native_models(home, endpoint) {
        Ok(ids) if ids != [] -> ids
        _ -> list.map(known(), fn(m) { m.id })
      }
    }
    _ -> []
  }
}

@external(erlang, "albedo_alibaba", "models")
fn native_models(home: String, endpoint: String) -> Result(List(String), String)

@external(erlang, "albedo_alibaba", "reload")
pub fn reload(home: String, endpoint: String) -> Result(List(String), String)
