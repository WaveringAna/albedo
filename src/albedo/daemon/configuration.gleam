import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

const not_configured = "provider is not configured; run /login"

const invalid_config = "provider configuration is invalid; run /login"

pub type Provider {
  Provider(
    name: String,
    extension: String,
    model: String,
    protocol: types.Protocol,
    effort: Option(String),
    image_edge: Option(Int),
    account_id: Option(String),
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
  case dict.has_key(config.providers, "default") {
    True -> configured(config, "default")
    False -> configured(config, config.active)
  }
}

fn configured(config: Configuration, name: String) -> Result(Provider, String) {
  use provider <- result.try(
    dict.get(config.providers, name)
    |> result.replace_error("active provider is not configured; run /login"),
  )
  use provider <- result.try(
    provider
    |> result.replace_error(invalid_config),
  )
  case
    string.trim(name) == ""
    || string.trim(provider.extension) == ""
    || string.trim(provider.model) == ""
  {
    True -> Error(invalid_config)
    False -> Ok(Provider(..provider, name: name))
  }
}

fn load(home: String) -> Result(Configuration, String) {
  use bytes <- result.try(
    read_config(home)
    |> result.replace_error(not_configured),
  )
  json.parse_bits(bytes, configuration_decoder())
  |> result.replace_error(invalid_config)
}

fn configuration_decoder() -> decode.Decoder(Configuration) {
  decode.one_of(named_decoder(), or: [legacy_decoder()])
}

fn named_decoder() -> decode.Decoder(Configuration) {
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

fn legacy_decoder() -> decode.Decoder(Configuration) {
  provider_decoder()
  |> decode.map(fn(provider) {
    Configuration("default", dict.from_list([#("default", Ok(provider))]))
  })
}

fn provider_decoder() -> decode.Decoder(Provider) {
  use provider_extension <- decode.optional_field(
    "extension",
    "openai",
    decode.string,
  )
  use model <- decode.field("model", decode.string)
  use protocol <- decode.field("protocol", types.protocol_decoder())
  use effort <- decode.optional_field(
    "effort",
    None,
    decode.optional(decode.string),
  )
  use image_edge <- decode.optional_field(
    "imageEdge",
    None,
    decode.optional(decode.int),
  )
  use account_id <- decode.optional_field(
    "accountId",
    None,
    decode.optional(decode.string),
  )
  decode.success(Provider(
    "",
    provider_extension,
    model,
    protocol,
    effort,
    image_edge,
    account_id,
  ))
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
    |> result.replace_error(not_configured),
  )
  use root <- result.try(
    json.parse_bits(bytes, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error(invalid_config),
  )
  let value = case dict.get(root, "providers") {
    Ok(providers) ->
      decode.run(providers, decode.dict(decode.string, decode.dynamic))
      |> result.replace_error(invalid_config)
      |> result.try(fn(providers) {
        dict.get(providers, name)
        |> result.replace_error(not_configured)
      })
    Error(_) if name == "default" ->
      json.parse_bits(bytes, decode.dynamic)
      |> result.replace_error(invalid_config)
    Error(_) -> Error(not_configured)
  }
  use value <- result.try(value |> result.replace_error(not_configured))
  decode.run(value, decoder)
  |> result.replace_error(invalid_config)
}

@external(erlang, "albedo_settings", "write_default")
pub fn select_default(
  home: String,
  provider: String,
  model: String,
) -> Result(Nil, String)

@external(erlang, "albedo_daemon", "read_config")
fn read_config(home: String) -> Result(BitArray, Nil)

/// Validate profiles at the daemon boundary without reporting secret values.
pub fn validate_profile(
  name: String,
  profile: Dynamic,
) -> Result(SavedProfile, String) {
  let invalid = "invalid provider name, model, protocol, endpoint, or API key"
  use profile <- result.try(
    decode.run(profile, saved_profile_decoder())
    |> result.replace_error(invalid),
  )
  let model = string.trim(profile.model)
  let endpoint = string.trim(profile.endpoint)
  let key_valid = case profile.api_key {
    None -> True
    Some(key) -> !has_control_characters(key, including_space: True)
  }
  case
    valid_provider_name(name)
    && string.byte_size(model) > 0
    && string.byte_size(model) <= 512
    && !has_control_characters(model, including_space: False)
    && profile.extension != ""
    && valid_endpoint(endpoint, profile.extension)
    && key_valid
  {
    False -> Error(invalid)
    True -> {
      Ok(
        SavedProfile(
          ..profile,
          endpoint: trim_endpoint_slashes(endpoint),
          model: model,
        ),
      )
    }
  }
}

pub type SavedProfile {
  SavedProfile(
    extension: String,
    endpoint: String,
    model: String,
    protocol: types.Protocol,
    api_key: Option(String),
  )
}

/// The native publisher keeps raw documents so unrelated fields survive edits.
pub fn named_config(config: Dynamic) -> Result(Dict(String, Dynamic), String) {
  use fields <- result.try(
    decode.run(config, decode.dict(decode.string, decode.dynamic))
    |> result.replace_error("invalid settings section"),
  )
  case dict.get(fields, "providers") {
    Ok(providers) -> {
      use _ <- result.try(
        decode.run(providers, decode.dict(decode.string, decode.dynamic))
        |> result.replace_error("invalid settings section"),
      )
      Ok(fields)
    }
    Error(_) ->
      case dict.size(fields) {
        0 -> Ok(dict.from_list([#("providers", dynamic.properties([]))]))
        _ ->
          Ok(
            fields
            |> dict.delete("apiKey")
            |> dict.insert("active", dynamic.string("default"))
            |> dict.insert(
              "providers",
              dynamic.properties([
                #(dynamic.string("default"), config),
              ]),
            ),
          )
      }
  }
}

pub fn normalize_profile(
  name: String,
  saved: Dynamic,
) -> Result(Dict(String, Dynamic), String) {
  use profile <- result.map(validate_profile(name, saved))
  let fields =
    dict.from_list([
      #("extension", dynamic.string(profile.extension)),
      #("baseUrl", dynamic.string(profile.endpoint)),
      #("model", dynamic.string(profile.model)),
      #("protocol", dynamic.string(types.protocol_name(profile.protocol))),
    ])
  case profile.api_key {
    None -> fields
    Some(key) -> dict.insert(fields, "apiKey", dynamic.string(key))
  }
}

pub fn validate_saved_config(
  config: Dynamic,
) -> Result(Dict(String, Dynamic), String) {
  use named <- result.try(named_config(config))
  let assert Ok(providers) = dict.get(named, "providers")
  let assert Ok(profiles) =
    decode.run(providers, decode.dict(decode.string, decode.dynamic))
  use _ <- result.try(
    list.try_each(dict.to_list(profiles), fn(entry) {
      validate_profile(entry.0, entry.1)
      |> result.map(fn(_) { Nil })
      |> result.replace_error("invalid config.json provider profile")
    }),
  )
  Ok(named)
}

fn saved_profile_decoder() -> decode.Decoder(SavedProfile) {
  use extension <- decode.optional_field("extension", "openai", decode.string)
  use endpoint <- decode.optional_field("baseUrl", "", decode.string)
  use model <- decode.field("model", decode.string)
  use protocol <- decode.field("protocol", types.protocol_decoder())
  use api_key <- decode.optional_field(
    "apiKey",
    None,
    decode.string |> decode.map(Some),
  )
  decode.success(SavedProfile(extension, endpoint, model, protocol, api_key))
}

fn valid_provider_name(name: String) -> Bool {
  case string.to_utf_codepoints(name) {
    [] -> False
    [first, ..rest] ->
      string.byte_size(name) <= 64
      && ascii_alphanumeric(string.utf_codepoint_to_int(first))
      && list.all(rest, fn(codepoint) {
        let value = string.utf_codepoint_to_int(codepoint)
        ascii_alphanumeric(value) || value == 46 || value == 95 || value == 45
      })
  }
}

fn ascii_alphanumeric(value: Int) -> Bool {
  value >= 48
  && value <= 57
  || value >= 65
  && value <= 90
  || value >= 97
  && value <= 122
}

fn has_control_characters(
  value: String,
  including_space include_space: Bool,
) -> Bool {
  value
  |> string.to_utf_codepoints
  |> list.any(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value < 32 || value == 127 || include_space && value == 32
  })
}

fn valid_endpoint(endpoint: String, extension: String) -> Bool {
  case endpoint {
    "" -> extension != "openai"
    _ -> {
      // uri.parse lowercases the scheme; saved profiles require its original
      // spelling to be http or https, as the previous validator did.
      let scheme_valid =
        string.starts_with(endpoint, "http:")
        || string.starts_with(endpoint, "https:")
      case uri.parse(endpoint) {
        Ok(parsed) ->
          scheme_valid
          && parsed.host != None
          && parsed.host != Some("")
          && parsed.userinfo == None
          && parsed.query == None
          && parsed.fragment == None
        Error(_) -> False
      }
    }
  }
}

fn trim_endpoint_slashes(endpoint: String) -> String {
  case string.ends_with(endpoint, "/") {
    True -> trim_endpoint_slashes(string.remove_suffix(endpoint, "/"))
    False -> endpoint
  }
}
