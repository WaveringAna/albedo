//// Antigravity's model table: limits, thinking controls, and the request
//// labels captured from the real antigravity/hub client.

import albedo/harness/extension
import albedo/harness/settings
import gleam/bool
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const endpoint = "https://daily-cloudcode-pa.googleapis.com"

pub type Family {
  Gemini
  Claude
}

/// How a model is asked to think: token budgets per effort, or Google's
/// named levels. Without a requested effort a model thinks at its high end.
pub type Thinking {
  Budget(low: Int, medium: Int, high: Int)
  Level
}

pub type Model {
  Model(
    id: String,
    name: String,
    context_tokens: Int,
    max_output_tokens: Int,
    images: Bool,
    thinking: Thinking,
    /// The opaque labels.model_enum token; Claude routes need none.
    model_enum: Option(String),
    /// The backend fixes generationConfig.maxOutputTokens for these ids.
    pinned_output: Bool,
  )
}

pub fn family(model: Model) -> Family {
  case string.starts_with(model.id, "claude-") {
    True -> Claude
    False -> Gemini
  }
}

/// Claude and GPT-OSS routes correlate function calls and responses by id.
pub fn correlates_calls(model: Model) -> Bool {
  string.starts_with(model.id, "claude-")
  || string.starts_with(model.id, "gpt-oss-")
}

/// Gemini before 3 cannot carry images inside a function response.
pub fn images_in_tool_results(model: Model) -> Bool {
  case string.split(model.id, "-") {
    ["gemini", version, ..] ->
      !{ string.starts_with(version, "1") || string.starts_with(version, "2") }
    _ -> True
  }
}

const flash_budget = Budget(1000, 4000, 10_000)

const pro_budget = Budget(1001, 8192, 10_001)

const default_budget = Budget(4096, 8192, 16_384)

/// What the backend last offered, with this table's thinking hints, or the
/// table itself before the first discovery.
pub fn models(home: String) -> List(Model) {
  refresh(home)
  case discovered(home) {
    [] -> known()
    offered -> offered
  }
}

fn discovered(home: String) -> List(Model) {
  let entry = {
    use id <- decode.field("id", decode.string)
    use name <- decode.field("name", decode.string)
    use context <- decode.field("context", decode.int)
    use output <- decode.field("output", decode.int)
    use images <- decode.field("images", decode.bool)
    use model_enum <- decode.optional_field(
      "modelEnum",
      None,
      decode.optional(decode.string),
    )
    let hint = hint(id)
    decode.success(Model(
      id,
      name,
      context,
      output,
      images,
      hint.thinking,
      model_enum,
      hint.pinned_output,
    ))
  }
  native_discovered(home)
  |> result.try(fn(bytes) {
    json.parse_bits(bytes, decode.at(["models"], decode.list(entry)))
    |> result.replace_error(Nil)
  })
  |> result.unwrap([])
}

/// The model table captured from the antigravity/hub client.
pub fn known() -> List(Model) {
  let gemini = fn(id, name, output, thinking) {
    Model(id, name, 1_048_576, output, True, thinking, None, False)
  }
  let claude = fn(id, name, context) {
    Model(id, name, context, 64_000, True, default_budget, None, False)
  }
  [
    claude("claude-opus-4-5-thinking", "Claude Opus 4.5", 200_000),
    Model(
      ..claude("claude-opus-4-6-thinking", "Claude Opus 4.6", 250_000),
      pinned_output: True,
    ),
    claude("claude-sonnet-4-5", "Claude Sonnet 4.5", 1_000_000),
    Model(
      ..claude("claude-sonnet-4-6", "Claude Sonnet 4.6", 250_000),
      pinned_output: True,
    ),
    gemini("gemini-2.5-flash", "Gemini 2.5 Flash", 65_535, default_budget),
    gemini(
      "gemini-2.5-flash-lite",
      "Gemini 2.5 Flash Lite",
      65_535,
      default_budget,
    ),
    gemini("gemini-2.5-pro", "Gemini 2.5 Pro", 65_536, default_budget),
    gemini("gemini-3-pro-low", "Gemini 3 Pro (Low)", 65_535, Level),
    gemini("gemini-3.1-flash-lite", "Gemini 3.1 Flash Lite", 65_535, Level),
    Model(
      ..gemini("gemini-3.1-pro-low", "Gemini 3.1 Pro (Low)", 65_535, pro_budget),
      model_enum: Some("MODEL_PLACEHOLDER_M36"),
      pinned_output: True,
    ),
    Model(
      ..gemini("gemini-pro-agent", "Gemini Pro Agent", 65_535, pro_budget),
      model_enum: Some("MODEL_PLACEHOLDER_M16"),
      pinned_output: True,
    ),
    Model(
      ..gemini(
        "gemini-3.5-flash-extra-low",
        "Gemini 3.5 Flash (Extra Low)",
        65_536,
        flash_budget,
      ),
      model_enum: Some("MODEL_PLACEHOLDER_M187"),
      pinned_output: True,
    ),
    Model(
      ..gemini(
        "gemini-3.5-flash-low",
        "Gemini 3.5 Flash (Low)",
        65_536,
        flash_budget,
      ),
      model_enum: Some("MODEL_PLACEHOLDER_M20"),
      pinned_output: True,
    ),
    Model(
      ..gemini(
        "gemini-3-flash-agent",
        "Gemini 3 Flash Agent",
        65_536,
        flash_budget,
      ),
      model_enum: Some("MODEL_PLACEHOLDER_M132"),
      pinned_output: True,
    ),
    gemini("gemini-3.6-flash-low", "Gemini 3.6 Flash (Low)", 65_536, Level),
    gemini("gemini-3.7-flash-low", "Gemini 3.7 Flash (Low)", 65_536, Level),
    Model(
      "gpt-oss-120b-medium",
      "GPT OSS 120B",
      131_072,
      32_768,
      False,
      // The backend rejects a larger budget for this route.
      Budget(4096, 8192, 8192),
      None,
      False,
    ),
  ]
}

/// A retired id follows the backend's rename, so saved profiles keep working.
pub fn model(home: String, id: String) -> Model {
  let id = renamed(home, id)
  models(home)
  |> list.find(fn(model) { model.id == id })
  |> result.lazy_unwrap(fn() { hint(id) })
}

fn renamed(home: String, id: String) -> String {
  native_discovered(home)
  |> result.try(fn(bytes) {
    json.parse_bits(bytes, decode.at(["renamed", id], decode.string))
    |> result.replace_error(Nil)
  })
  |> result.unwrap(id)
}

/// A known model, or one inferred from its family so a newly released id
/// still gets the right thinking control.
fn hint(id: String) -> Model {
  known()
  |> list.find(fn(model) { model.id == id })
  |> result.lazy_unwrap(fn() {
    Model(id, id, 200_000, 64_000, True, infer_thinking(id), None, False)
  })
}

fn infer_thinking(id: String) -> Thinking {
  let id = string.lowercase(id)
  let gemini_3 =
    string.starts_with(id, "gemini-3-") || string.starts_with(id, "gemini-3.")
  case gemini_3 {
    False -> default_budget
    True ->
      case
        string.starts_with(id, "gemini-3-pro")
        || string.starts_with(id, "gemini-3.6-flash")
        || string.starts_with(id, "gemini-3.7-flash")
        || id == "gemini-3.1-flash-lite"
      {
        True -> Level
        False ->
          case string.contains(id, "flash") {
            True -> flash_budget
            False -> pro_budget
          }
      }
  }
}

pub fn catalog() -> extension.ModelCatalog {
  extension.ModelCatalog(lookup, list_models)
}

/// Answers only for the Antigravity endpoint, so models.dev keeps every
/// other provider's facts for a shared id such as claude-sonnet-4-6.
fn lookup(id: String, at: String) -> Option(extension.ModelInfo) {
  use <- bool.guard(string.remove_suffix(at, "/") != endpoint, None)
  case list.find(models(settings.home()), fn(model) { model.id == id }) {
    Error(_) -> None
    Ok(model) ->
      Some(extension.ModelInfo(
        model.id,
        "antigravity",
        Some(model.context_tokens),
        Some(model.max_output_tokens),
        case model.images {
          True -> ["text", "image"]
          False -> ["text"]
        },
        Some(endpoint),
        [],
        "antigravity model discovery cached in " <> settings.home(),
      ))
  }
}

/// The first listing after sign-in waits for discovery, so /login never
/// offers ids the backend has already retired.
fn list_models(provider: String, _endpoint: String) -> List(String) {
  case provider {
    "antigravity" -> {
      let home = settings.home()
      case discovered(home) {
        [] -> {
          let _ = native_reload(home)
          models(home)
        }
        offered -> offered
      }
      |> list.map(fn(model) { model.id })
    }
    _ -> []
  }
}

@external(erlang, "albedo_antigravity", "discovered")
fn native_discovered(home: String) -> Result(BitArray, Nil)

@external(erlang, "albedo_antigravity", "refresh")
fn refresh(home: String) -> Nil

@external(erlang, "albedo_antigravity", "reload")
fn native_reload(home: String) -> Result(Nil, String)
