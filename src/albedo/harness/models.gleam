//// models.dev catalog: model limits, modalities, and provider endpoints.
//// The catalog is cached on disk and read locally; it is never invented.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/settings
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None}

const catalog_file = "models.json"

const default_url = "https://models.dev/api.json"

const default_refresh_hours = 24

pub type Config {
  Config(url: String, refresh_hours: Int)
}

pub fn default_config() -> Config {
  Config(default_url, default_refresh_hours)
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
    [extension.ModelsPlugin(lookup)],
    initialise,
  )
}

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  refresh()
  Ok(Nil)
}

/// Refresh the cache in the background when it is missing or older than the
/// configured window. A failed fetch keeps the previous cache.
pub fn refresh() -> Nil {
  case settings.load("models", config_decoder(), default_config()) {
    Ok(Config(url, hours)) if hours > 0 ->
      native_refresh(path(), url, hours * 3_600_000)
    _ -> Nil
  }
}

pub fn path() -> String {
  settings.home() <> "/" <> catalog_file
}

/// `endpoint` is the configured provider base url. It disambiguates a model id
/// that several catalog providers publish.
pub fn lookup(model: String, endpoint: String) -> Option(extension.ModelInfo) {
  refresh()
  lookup_at(path(), model, endpoint)
}

pub fn lookup_at(
  catalog: String,
  model: String,
  endpoint: String,
) -> Option(extension.ModelInfo) {
  case native_lookup(catalog, model, endpoint) {
    Error(_) -> None
    Ok(encoded) ->
      json.parse(encoded, info_decoder(catalog))
      |> option.from_result
  }
}

fn info_decoder(catalog: String) {
  use model <- decode.field("model", decode.string)
  use provider <- decode.field("provider", decode.string)
  use context <- decode.optional_field(
    "context",
    None,
    decode.optional(decode.int),
  )
  use output <- decode.optional_field(
    "output",
    None,
    decode.optional(decode.int),
  )
  use modalities <- decode.optional_field(
    "input_modalities",
    [],
    decode.list(decode.string),
  )
  use api <- decode.optional_field("api", None, decode.optional(decode.string))
  use env <- decode.optional_field("env", [], decode.list(decode.string))
  use matched <- decode.field("matched", decode.string)
  decode.success(extension.ModelInfo(
    model,
    provider,
    context,
    output,
    modalities,
    api,
    env,
    "models.dev catalog cached at " <> catalog <> "; matched by " <> matched,
  ))
}

@external(erlang, "albedo_models", "refresh")
fn native_refresh(catalog: String, url: String, max_age_ms: Int) -> Nil

@external(erlang, "albedo_models", "lookup")
fn native_lookup(
  catalog: String,
  model: String,
  endpoint: String,
) -> Result(String, String)
