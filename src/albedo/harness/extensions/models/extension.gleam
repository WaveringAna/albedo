//// models.dev catalog: model limits, modalities, and provider endpoints.
//// The catalog is cached on disk and read locally; it is never invented.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/models/catalog.{type LookupError, MissingModel}
import albedo/harness/settings
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const catalog_file = "models.json"

const default_url = "https://models.dev/api.json"

const default_refresh_hours = 24

pub type Config {
  Config(url: String, refresh_hours: Int)
}

pub fn default_config() -> Config {
  Config(default_url, default_refresh_hours)
}

fn infer_reasoning_efforts(model: String) -> List(String) {
  let id = string.lowercase(model)
  let reasoning =
    string.starts_with(id, "o1")
    || string.starts_with(id, "o3")
    || string.starts_with(id, "o4")
    || string.starts_with(id, "gpt-5")
    || string.contains(id, "reasoner")
    || string.contains(id, "reasoning")
    || string.contains(id, "thinking")
  case reasoning {
    True -> ["low", "medium", "high"]
    False -> []
  }
}

pub fn config_decoder() {
  use url <- decode.optional_field("url", default_url, decode.string)
  use hours <- decode.optional_field(
    "refreshHours",
    default_refresh_hours,
    decode.int,
  )
  decode.success(Config(url, hours))
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "models",
    "models.dev catalog of model context limits, modalities, and provider endpoints",
    [],
    [extension.ModelsPlugin(extension.ModelCatalog(lookup, list, Some(reload)))],
    initialise,
  )
}

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  refresh()
  Ok(Nil)
}

fn load_config() -> Result(Config, String) {
  settings.load("models", config_decoder(), default_config())
}

/// Refresh the cache in the background when it is missing or older than the
/// configured window. A failed fetch keeps the previous cache.
fn refresh() -> Nil {
  case load_config() {
    Ok(Config(url, hours)) if hours > 0 ->
      native_refresh(path(), url, hours * 3_600_000)
    _ -> Nil
  }
}

/// Fetch and atomically replace the cached catalog now, regardless of its age.
/// Unlike the opportunistic background refresh, this reports fetch failures so
/// an explicit `/reload models` never claims stale data was refreshed.
pub fn reload() -> Result(Nil, String) {
  use Config(url, _) <- result.try(load_config())
  native_reload(path(), url)
}

fn path() -> String {
  settings.home() <> "/" <> catalog_file
}

/// `endpoint` is the configured provider base url. It disambiguates a model id
/// that several catalog providers publish.
pub fn lookup(
  model: String,
  endpoint: Option(String),
) -> Option(extension.ModelInfo) {
  refresh()
  let catalog = path()
  case native_lookup(catalog, model, option.unwrap(endpoint, "")) {
    Error(MissingModel) -> {
      let efforts = infer_reasoning_efforts(model)
      case efforts {
        [] -> None
        _ ->
          Some(
            extension.ModelInfo(
              ..extension.blank_model(model, "models"),
              source: "inferred reasoning model",
              efforts: efforts,
            ),
          )
      }
    }
    Error(_) -> None
    Ok(info) -> Some(with_source(info, catalog))
  }
}

/// Exact models.dev provider namespace; avoids selecting another provider's
/// conflicting limits when the provider omits an API endpoint.
pub fn lookup_provider(
  provider: String,
  model: String,
) -> Option(extension.ModelInfo) {
  refresh()
  let catalog = path()
  case native_lookup_provider(catalog, provider, model) {
    Ok(info) -> Some(with_source(info, catalog))
    Error(_) -> None
  }
}

pub fn list(provider: String, endpoint: Option(String)) -> List(String) {
  refresh()
  native_list(path(), provider, option.unwrap(endpoint, ""))
  |> result.unwrap([])
}

fn with_source(
  info: extension.ModelInfo,
  catalog: String,
) -> extension.ModelInfo {
  extension.ModelInfo(
    ..info,
    source: "models.dev catalog cached at "
      <> catalog
      <> "; matched by "
      <> info.source,
  )
}

@external(erlang, "albedo_models", "refresh")
fn native_refresh(catalog: String, url: String, max_age_ms: Int) -> Nil

@external(erlang, "albedo_models", "reload")
fn native_reload(catalog: String, url: String) -> Result(Nil, String)

@external(erlang, "albedo_models", "lookup")
fn native_lookup(
  catalog: String,
  model: String,
  endpoint: String,
) -> Result(extension.ModelInfo, LookupError)

@external(erlang, "albedo_models", "lookup_provider")
fn native_lookup_provider(
  catalog: String,
  provider: String,
  model: String,
) -> Result(extension.ModelInfo, LookupError)

@external(erlang, "albedo_models", "list")
fn native_list(
  catalog: String,
  provider: String,
  endpoint: String,
) -> Result(List(String), String)

/// Fills in missing fields of a ModelInfo (context tokens, max output tokens,
/// input modalities, efforts, endpoint, environment) by looking up the model
/// in the models.dev catalog. If the model is not found, the base ModelInfo
/// is returned unchanged.
pub fn complete_model(
  info: extension.ModelInfo,
  endpoint: Option(String),
) -> extension.ModelInfo {
  case lookup(info.model, endpoint) {
    Some(found) -> fill_info(info, found)
    None -> info
  }
}

fn fill_info(
  base: extension.ModelInfo,
  found: extension.ModelInfo,
) -> extension.ModelInfo {
  extension.ModelInfo(
    ..base,
    provider: case base.provider {
      "" -> found.provider
      p -> p
    },
    context_tokens: option.or(base.context_tokens, found.context_tokens),
    max_context_tokens: option.or(
      base.max_context_tokens,
      found.max_context_tokens,
    ),
    max_output_tokens: option.or(
      base.max_output_tokens,
      found.max_output_tokens,
    ),
    input_modalities: fallback_list(
      base.input_modalities,
      found.input_modalities,
    ),
    endpoint: option.or(base.endpoint, found.endpoint),
    environment: fallback_list(base.environment, found.environment),
    source: base.source <> "; enriched from " <> found.source,
    efforts: fallback_list(base.efforts, found.efforts),
  )
}

fn fallback_list(base: List(a), fallback: List(a)) -> List(a) {
  case base {
    [] -> fallback
    _ -> base
  }
}
