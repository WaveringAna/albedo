//// Antigravity's model table: limits, thinking controls, and the request
//// labels captured from the real antigravity/hub client.

import albedo/harness/extension
import albedo/harness/extensions/models/extension as models
import albedo/harness/settings
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
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
  discovered(home)
}

fn decode_discovered(
  home: String,
  decoder: decode.Decoder(a),
) -> Result(a, Nil) {
  use bytes <- result.try(native_discovered(home))
  json.parse_bits(bytes, decoder) |> result.replace_error(Nil)
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
  decode_discovered(home, decode.at(["models"], decode.list(entry)))
  |> result.unwrap([])
}

const effort_suffixes = [
  #("-extra-low", "extra-low"),
  #("-low", "low"),
  #("-medium", "medium"),
  #("-high", "high"),
]

/// Splits a model id into its base model id and effort tier.
/// Maps "gemini-pro-agent" to base "gemini-3.1-pro" and effort "high".
pub fn split_id(id: String) -> #(String, Option(String)) {
  case id {
    "gemini-pro-agent" -> #("gemini-3.1-pro", Some("high"))
    _ ->
      list.find_map(effort_suffixes, fn(pair) {
        case string.ends_with(id, pair.0) {
          True ->
            Ok(#(string.drop_end(id, string.length(pair.0)), Some(pair.1)))
          False -> Error(Nil)
        }
      })
      |> result.unwrap(#(id, None))
  }
}

fn effort_rank(effort: String) -> Int {
  case effort {
    "extra-low" | "minimal" -> 0
    "low" -> 1
    "medium" -> 2
    "high" -> 3
    "xhigh" -> 4
    "max" -> 5
    _ -> 6
  }
}

pub fn sort_efforts(efforts: List(String)) -> List(String) {
  list.sort(efforts, fn(a, b) { int.compare(effort_rank(a), effort_rank(b)) })
}

/// Available reasoning efforts for a base or variant model id.
pub fn available_efforts(home: String, id: String) -> List(String) {
  let #(base_id, _) = split_id(renamed(home, id))
  models(home)
  |> list.filter_map(fn(m) {
    let #(b, e) = split_id(m.id)
    case b == base_id {
      True -> option.to_result(e, Nil)
      False -> Error(Nil)
    }
  })
  |> list.unique
  |> sort_efforts
}

/// Base model ids discovered from Antigravity, deduplicated while preserving
/// first-seen order.
pub fn base_model_ids(home: String) -> List(String) {
  models(home)
  |> list.map(fn(m) { split_id(m.id).0 })
  |> list.unique
}

/// Resolves a base or variant model id and optional effort to an exact backend Model variant.
pub fn resolve_variant(
  home: String,
  id: String,
  effort: Option(String),
) -> Model {
  let all = models(home)
  let ren = renamed(home, id)
  let #(base_id, id_effort) = split_id(ren)
  let target_effort = option.or(effort, id_effort)
  let variants =
    list.filter_map(all, fn(m) {
      let #(b, e) = split_id(m.id)
      case b == base_id {
        True -> Ok(#(e, m))
        False -> Error(Nil)
      }
    })
  case variants {
    [] ->
      case list.find(all, fn(m) { m.id == ren }) {
        Ok(m) -> m
        Error(_) -> hint(ren)
      }
    _ -> {
      let eff = case target_effort {
        Some(e) -> e
        None ->
          variants
          |> list.filter_map(fn(p) { option.to_result(p.0, Nil) })
          |> extension.default_effort
          |> option.unwrap("medium")
      }
      [Some(eff), Some("medium"), Some("high")]
      |> list.find_map(list.key_find(variants, _))
      |> result.lazy_or(fn() { list.first(variants) |> result.map(pair.second) })
      |> result.unwrap(hint(ren))
    }
  }
}

/// A retired id follows the backend's rename, so saved profiles keep working.
pub fn model(home: String, id: String, effort: Option(String)) -> Model {
  let id = renamed(home, id)
  resolve_variant(home, id, effort)
}

fn renamed(home: String, id: String) -> String {
  decode_discovered(home, decode.at(["renamed", id], decode.string))
  |> result.unwrap(id)
}

/// An inferred model from its family so a newly released id
/// still gets the right thinking control.
fn hint(id: String) -> Model {
  Model(id, id, 200_000, 64_000, True, infer_thinking(id), None, False)
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
  extension.ModelCatalog(
    lookup,
    list_models,
    Some(fn() { native_reload(settings.home()) }),
  )
}

/// Answers only for the Antigravity endpoint, so models.dev keeps every
/// other provider's facts for a shared id such as claude-sonnet-4-6.
fn lookup(id: String, at: Option(String)) -> Option(extension.ModelInfo) {
  use <- bool.guard(
    case at {
      Some(url) -> string.remove_suffix(url, "/") != endpoint
      None -> False
    },
    None,
  )
  let home = settings.home()
  let ren = renamed(home, id)
  let #(base_id, _) = split_id(ren)
  let all = models(home)
  let matches_base = list.any(all, fn(m) { split_id(m.id).0 == base_id })
  let matches_raw = list.any(all, fn(m) { m.id == id || m.id == ren })
  use <- bool.guard(!matches_base && !matches_raw, None)
  let efforts = available_efforts(home, base_id)
  let variant = resolve_variant(home, id, extension.default_effort(efforts))
  let info =
    extension.ModelInfo(
      ..extension.blank_model(base_id, "antigravity"),
      context_tokens: Some(variant.context_tokens),
      max_output_tokens: Some(variant.max_output_tokens),
      input_modalities: case variant.images {
        True -> ["text", "image"]
        False -> ["text"]
      },
      endpoint: Some(endpoint),
      source: "antigravity model discovery cached in " <> home,
      efforts: efforts,
    )
  Some(models.complete_model(info, at))
}

/// The first listing after sign-in waits for discovery, so /login never
/// offers ids the backend has already retired. Returns deduplicated base model ids.
fn list_models(provider: String, _endpoint: Option(String)) -> List(String) {
  case provider {
    "antigravity" -> {
      let home = settings.home()
      case discovered(home) {
        [] -> {
          let _ = native_reload(home)
          Nil
        }
        _ -> Nil
      }
      base_model_ids(home)
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
