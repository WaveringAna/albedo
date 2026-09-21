import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/result
import gleam/string

pub type Provider {
  Provider(
    name: String,
    base_url: String,
    api_key: String,
    model: String,
    protocol: types.Protocol,
  )
}

type Configuration {
  Configuration(active: String, providers: Dict(String, Provider))
}

pub fn active(home: String) -> Result(Provider, String) {
  use config <- result.try(load(home))
  configured(config, config.active)
}

pub fn named(home: String, name: String) -> Result(Provider, String) {
  use config <- result.try(load(home))
  configured(config, name)
  |> result.replace_error("session provider is not configured; run /login")
}

// A migrated flat config remains "default" even if login selected a new provider.
pub fn legacy(home: String) -> Result(Provider, String) {
  use config <- result.try(load(home))
  case dict.get(config.providers, "default") {
    Ok(_) -> configured(config, "default")
    Error(_) -> configured(config, config.active)
  }
}

fn configured(config: Configuration, name: String) -> Result(Provider, String) {
  use provider <- result.try(
    dict.get(config.providers, name)
    |> result.replace_error("active provider is not configured; run /login"),
  )
  case
    string.trim(name) == ""
    || string.trim(provider.base_url) == ""
    || string.trim(provider.api_key) == ""
    || string.trim(provider.model) == ""
  {
    True -> Error("provider configuration is invalid; run /login")
    False -> Ok(Provider(..provider, name: name))
  }
}

fn load(home: String) -> Result(Configuration, String) {
  use bytes <- result.try(
    read_config(home)
    |> result.replace_error("provider is not configured; run /login"),
  )
  json.parse_bits(bytes, configuration_decoder())
  |> result.replace_error("provider configuration is invalid; run /login")
}

fn configuration_decoder() {
  decode.one_of(named_decoder(), or: [legacy_decoder()])
}

fn named_decoder() {
  use active <- decode.optional_field("active", "", decode.string)
  use providers <- decode.field(
    "providers",
    decode.dict(decode.string, provider_decoder()),
  )
  decode.success(Configuration(active, providers))
}

fn legacy_decoder() {
  provider_decoder()
  |> decode.map(fn(provider) {
    Configuration("default", dict.from_list([#("default", provider)]))
  })
}

fn provider_decoder() {
  use base_url <- decode.field("baseUrl", decode.string)
  use api_key <- decode.field("apiKey", decode.string)
  use model <- decode.field("model", decode.string)
  use protocol <- decode.field("protocol", protocol_decoder())
  decode.success(Provider("", base_url, api_key, model, protocol))
}

fn protocol_decoder() {
  decode.string
  |> decode.then(fn(value) {
    case value {
      "responses" -> decode.success(types.Responses)
      "chat_completions" -> decode.success(types.ChatCompletions)
      _ -> decode.failure(types.Responses, "provider protocol")
    }
  })
}

@external(erlang, "albedo_daemon", "read_config")
fn read_config(home: String) -> Result(BitArray, Nil)
