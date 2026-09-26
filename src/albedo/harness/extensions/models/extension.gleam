//// models.dev catalog: model limits, modalities, and provider endpoints.
//// The catalog is cached on disk and read locally; it is never invented.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/settings
import gleam/dynamic/decode
import gleam/json
import gleam/list
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

pub fn infer_reasoning_efforts(model: String) -> List(String) {
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
    [extension.ModelsPlugin(extension.ModelCatalog(lookup, list))],
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

/// Fetch and atomically replace the cached catalog now, regardless of its age.
/// Unlike the opportunistic background refresh, this reports fetch failures so
/// an explicit `/reload models` never claims stale data was refreshed.
pub fn reload() -> Result(Nil, String) {
  use Config(url, _) <- result.try(settings.load(
    "models",
    config_decoder(),
    default_config(),
  ))
  reload_at(path(), url)
}

pub fn reload_at(catalog: String, url: String) -> Result(Nil, String) {
  native_reload(catalog, url)
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
    Error(_) -> {
      let efforts = infer_reasoning_efforts(model)
      case efforts {
        [] -> None
        _ ->
          Some(extension.ModelInfo(
            model,
            "models",
            None,
            None,
            [],
            None,
            [],
            "inferred reasoning model",
            efforts,
          ))
      }
    }
    Ok(encoded) ->
      json.parse(encoded, info_decoder(catalog))
      |> option.from_result
  }
}

/// Exact models.dev provider namespace; avoids selecting another provider's
/// conflicting limits when the provider omits an API endpoint.
pub fn lookup_provider(
  provider: String,
  model: String,
) -> Option(extension.ModelInfo) {
  refresh()
  lookup_provider_at(path(), provider, model)
}

pub fn lookup_provider_at(
  catalog: String,
  provider: String,
  model: String,
) -> Option(extension.ModelInfo) {
  case native_lookup_provider(catalog, provider, model) {
    Ok(encoded) ->
      json.parse(encoded, info_decoder(catalog)) |> option.from_result
    Error(_) -> None
  }
}

pub fn list(provider: String, endpoint: String) -> List(String) {
  refresh()
  list_at(path(), provider, endpoint)
}

pub fn list_at(
  catalog: String,
  provider: String,
  endpoint: String,
) -> List(String) {
  case native_list(catalog, provider, endpoint) {
    Error(_) -> []
    Ok(encoded) ->
      json.parse(encoded, decode.list(decode.string))
      |> result.unwrap([])
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
  use efforts <- decode.optional_field(
    "efforts",
    [],
    decode.list(decode.string),
  )
  let resolved_efforts = case efforts {
    [] -> infer_reasoning_efforts(model)
    _ -> efforts
  }
  decode.success(extension.ModelInfo(
    model,
    provider,
    context,
    output,
    modalities,
    api,
    env,
    "models.dev catalog cached at " <> catalog <> "; matched by " <> matched,
    resolved_efforts,
  ))
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
) -> Result(String, String)

@external(erlang, "albedo_models", "lookup_provider")
fn native_lookup_provider(
  catalog: String,
  provider: String,
  model: String,
) -> Result(String, String)

@external(erlang, "albedo_models", "list")
fn native_list(
  catalog: String,
  provider: String,
  endpoint: String,
) -> Result(String, String)

/// Fills in missing fields of a ModelInfo (context tokens, max output tokens,
/// input modalities, efforts, endpoint, environment) by looking up the model
/// in the models.dev catalog. If the model is not found, the base ModelInfo
/// is returned unchanged.
pub fn complete_model(
  info: extension.ModelInfo,
  endpoint: String,
) -> extension.ModelInfo {
  case complete_models([info], endpoint) {
    [completed, ..] -> completed
    _ -> info
  }
}

/// Batch completes a list of ModelInfo records against models.dev.
/// Refreshes the models.dev cache at most once across the entire batch,
/// then resolves each model against the local index.
pub fn complete_models(
  models: List(extension.ModelInfo),
  endpoint: String,
) -> List(extension.ModelInfo) {
  refresh()
  complete_models_at(path(), models, endpoint)
}

/// Batch completes ModelInfo records using a specific catalog file path.
pub fn complete_models_at(
  catalog_path: String,
  models: List(extension.ModelInfo),
  endpoint: String,
) -> List(extension.ModelInfo) {
  list.map(models, fn(item) {
    case lookup_at(catalog_path, item.model, endpoint) {
      Some(found) -> fill_info(item, found)
      None -> item
    }
  })
}

fn fill_info(
  base: extension.ModelInfo,
  found: extension.ModelInfo,
) -> extension.ModelInfo {
  extension.ModelInfo(
    model: base.model,
    provider: case base.provider {
      "" -> found.provider
      p -> p
    },
    context_tokens: case base.context_tokens {
      Some(_) -> base.context_tokens
      None -> found.context_tokens
    },
    max_output_tokens: case base.max_output_tokens {
      Some(_) -> base.max_output_tokens
      None -> found.max_output_tokens
    },
    input_modalities: case base.input_modalities {
      [] -> found.input_modalities
      mods -> mods
    },
    endpoint: case base.endpoint {
      Some(_) -> base.endpoint
      None -> found.endpoint
    },
    environment: case base.environment {
      [] -> found.environment
      env -> env
    },
    source: base.source <> "; enriched from " <> found.source,
    efforts: case base.efforts {
      [] -> found.efforts
      eff -> eff
    },
  )
}
