//// Alibaba Model Studio provider over the OpenAI-compatible Chat Completions API.

import albedo/harness/extension
import albedo/harness/extensions/alibaba/catalog
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub const provider_name = "alibaba"

pub fn extension() -> extension.Extension {
  extension.Extension(
    provider_name,
    "Alibaba Model Studio provider for Qwen, DeepSeek, and GLM models; a rate-limited key hands off to the other alibaba profiles' keys",
    [],
    [
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider(
        provider_name,
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(
    context,
    "alibaba",
    "Alibaba",
    types.ChatCompletions,
  )
  let pool = pool(context.home, context.profile, context.session)
  use client <- result.map(pool.current())
  rotation.client_upstream(
    pool,
    client,
    fn(client, error) {
      explain_key(context.home, context.profile, client, error)
    },
    fn(client) { rotation.key_label(client.api_key) },
  )
}

/// Every Alibaba key albedo can see, as a rotation pool: the profile's own key
/// first, then other alibaba profiles, auth.json, and the environment.
pub fn pool(
  home: String,
  profile: String,
  session: String,
) -> rotation.Pool(types.Client) {
  rotation.Pool(
    current: fn() { connect(home, profile, session) },
    mark: fn(client, body) {
      limited(home, profile, client, body) |> rotation.mark_limit
    },
    same: rotation.same_client,
    stream: openai_api.stream,
  )
}

fn connect(
  home: String,
  profile: String,
  session: String,
) -> Result(types.Client, String) {
  use encoded <- result.try(native_access(home, profile, session))
  let decoder = {
    use base_url <- decode.field("baseUrl", decode.string)
    use api_key <- decode.field("apiKey", decode.string)
    decode.success(#(base_url, api_key))
  }
  case json.parse(encoded, decoder) {
    Ok(#(base_url, _)) if base_url == "" -> Error("Alibaba base URL is invalid")
    Ok(#(base_url, api_key)) ->
      Ok(openai_api.client(types.ChatCompletions, base_url, api_key))
    Error(_) -> Error("invalid Alibaba credential response")
  }
}

fn limited(
  home: String,
  profile: String,
  client: types.Client,
  body: String,
) -> Result(rotation.Limited, Nil) {
  native_limited(home, profile, client.api_key, body)
  |> result.replace_error(Nil)
  |> result.try(rotation.decode_limited)
}

/// A 429 reaching here has already been tried on every sibling key with room.
fn explain_key(
  home: String,
  profile: String,
  client: types.Client,
  error: types.Error,
) -> Option(String) {
  case error {
    types.HttpError(429, body) ->
      case limited(home, profile, client, body) {
        Ok(limit) if limit.next != "" ->
          Some(rotation.next_turn_message(
            "Alibaba Model Studio limit reached until " <> limit.until,
            limit.next,
          ))
        _ -> explain(error)
      }
    _ -> explain(error)
  }
}

pub fn explain(error: types.Error) -> Option(String) {
  case error {
    types.HttpError(401, _) ->
      Some(
        "Alibaba Model Studio rejected the API key; check your key or ALIBABA_API_KEY",
      )
    types.HttpError(429, body) ->
      Some(case string.contains(body, "Allocated quota exceeded") {
        True ->
          "Alibaba Model Studio rate limit (TPM/TPS) exceeded; wait a few seconds and retry"
        False ->
          "Alibaba Model Studio request limit reached: "
          <> rotation.error_message(body)
      })
    types.HttpError(status, body) ->
      Some(
        "Alibaba Model Studio error ("
        <> int.to_string(status)
        <> "): "
        <> rotation.error_message(body),
      )
    _ -> None
  }
}

@external(erlang, "albedo_alibaba", "access")
fn native_access(
  home: String,
  profile: String,
  session: String,
) -> Result(String, String)

@external(erlang, "albedo_alibaba", "limited")
fn native_limited(
  home: String,
  profile: String,
  api_key: String,
  body: String,
) -> Result(String, String)
