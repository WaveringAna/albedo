import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result
import gleam/string

pub type Provider {
  Provider(
    name: String,
    extension: String,
    model: String,
    protocol: types.Protocol,
  )
}

/// Each saved profile decodes on its own, so one malformed entry makes only
/// that profile unusable.
type Configuration {
  Configuration(active: String, providers: Dict(String, Result(Provider, Nil)))
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

/// Every valid saved profile, by name.
pub fn providers(home: String) -> Result(List(Provider), String) {
  profiles(home) |> result.map(result.values)
}

/// Every saved profile by name: usable, or the profile name and why not.
pub fn profiles(
  home: String,
) -> Result(List(Result(Provider, #(String, String))), String) {
  use config <- result.map(load(home))
  config.providers
  |> dict.keys
  |> list.sort(string.compare)
  |> list.map(fn(name) {
    configured(config, name) |> result.map_error(fn(error) { #(name, error) })
  })
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
  use provider <- result.try(
    provider
    |> result.replace_error("provider configuration is invalid; run /login"),
  )
  case
    string.trim(name) == ""
    || string.trim(provider.extension) == ""
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
    decode.dict(
      decode.string,
      decode.dynamic
        |> decode.map(fn(value) {
          decode.run(value, provider_decoder()) |> result.replace_error(Nil)
        }),
    ),
  )
  decode.success(Configuration(active, providers))
}

fn legacy_decoder() {
  provider_decoder()
  |> decode.map(fn(provider) {
    Configuration("default", dict.from_list([#("default", Ok(provider))]))
  })
}

fn provider_decoder() {
  use provider_extension <- decode.optional_field(
    "extension",
    "openai",
    decode.string,
  )
  use model <- decode.field("model", decode.string)
  use protocol <- decode.field("protocol", protocol_decoder())
  decode.success(Provider("", provider_extension, model, protocol))
}

/// Decode one provider's extension-owned settings without exposing credentials
/// through the generic configuration type.
pub fn settings(
  home: String,
  name: String,
  decoder: decode.Decoder(a),
) -> Result(a, String) {
  use bytes <- result.try(
    read_config(home)
    |> result.replace_error("provider is not configured; run /login"),
  )
  use root <- result.try(
    json.parse_bits(bytes, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("provider configuration is invalid; run /login"),
  )
  let value = case dict.get(root, "providers") {
    Ok(providers) ->
      decode.run(providers, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error("provider configuration is invalid; run /login")
      |> result.try(fn(providers) {
        dict.get(providers, name)
        |> result.replace_error("provider is not configured; run /login")
      })
    Error(_) if name == "default" ->
      json.parse_bits(bytes, decode.dynamic)
      |> result.replace_error("provider configuration is invalid; run /login")
    Error(_) -> Error("provider is not configured; run /login")
  }
  use value <- result.try(
    value
    |> result.replace_error("provider is not configured; run /login"),
  )
  decode.run(value, decoder)
  |> result.replace_error("provider configuration is invalid; run /login")
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

pub fn select_default(
  home: String,
  provider: String,
  model: String,
) -> Result(Nil, String) {
  write_default(home, provider, model)
}

@external(erlang, "albedo_daemon", "write_default")
fn write_default(
  home: String,
  provider: String,
  model: String,
) -> Result(Nil, String)

@external(erlang, "albedo_daemon", "read_config")
fn read_config(home: String) -> Result(BitArray, Nil)
