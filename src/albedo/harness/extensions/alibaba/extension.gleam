//// Alibaba Model Studio provider over the OpenAI-compatible Chat Completions API.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/alibaba/catalog
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
    "Alibaba Model Studio provider for Qwen, DeepSeek, and GLM models",
    [],
    [
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider(
        provider_name,
        resolve,
      )),
    ],
    initialise,
  )
}

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  Ok(Nil)
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  case context.provider {
    "alibaba" ->
      case context.protocol {
        types.ChatCompletions ->
          Some({
            use #(base_url, api_key) <- result.try(native_resolve_credentials(
              context.home,
              context.profile,
            ))
            case string.trim(api_key) == "" {
              True ->
                Error(
                  "Alibaba API key not found; set ALIBABA_API_KEY, add to auth.json, or configure in /login",
                )
              False ->
                case string.trim(base_url) == "" {
                  True -> Error("Alibaba base URL is invalid")
                  False -> {
                    let client =
                      openai_api.client(context.protocol, base_url, api_key)
                    Ok(upstream(client))
                  }
                }
            }
          })
        _ ->
          Some(Error("Alibaba provider requires the chat_completions protocol"))
      }
    _ -> None
  }
}

pub fn upstream(client: types.Client) -> extension.Upstream {
  extension.Upstream(
    client.base_url,
    client.protocol,
    fn(request, on_event) { openai_api.stream(client, request, on_event) },
    explain,
  )
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
          "Alibaba Model Studio request limit reached: " <> error_message(body)
      })
    types.HttpError(status, body) ->
      Some(
        "Alibaba Model Studio error ("
        <> int.to_string(status)
        <> "): "
        <> error_message(body),
      )
    _ -> None
  }
}

fn error_message(body: String) -> String {
  json.parse(body, decode.at(["error", "message"], decode.string))
  |> result.unwrap(body)
}

@external(erlang, "albedo_alibaba", "resolve_credentials")
fn native_resolve_credentials(
  home: String,
  profile: String,
) -> Result(#(String, String), String)
