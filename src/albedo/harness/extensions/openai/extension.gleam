//// Generic OpenAI-compatible provider authentication and client construction.

import albedo/daemon/configuration
import albedo/harness/extension
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Config {
  Config(base_url: String, api_key: String)
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "openai",
    "API-key authentication for OpenAI-compatible Responses and Chat Completions providers",
    ["models"],
    [extension.ModelProviderPlugin(extension.ModelProvider("openai", resolve))],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- bool.guard(context.provider != "openai", None)
  Some({
    use config <- result.try(configuration.settings(
      context.home,
      context.profile,
      config_decoder(),
    ))
    case
      string.trim(config.base_url) == ""
      || string.trim(config.api_key) == ""
      || string.contains(config.api_key, "\r")
      || string.contains(config.api_key, "\n")
    {
      True -> Error("OpenAI provider configuration is invalid; run /login")
      False ->
        openai_api.client(context.protocol, config.base_url, config.api_key)
        |> upstream(fn(_) { None })
        |> Ok
    }
  })
}

/// An upstream served by the shared OpenAI stream.
pub fn upstream(
  client: types.Client,
  explain: fn(types.Error) -> Option(String),
) -> extension.Upstream {
  extension.Upstream(
    client.base_url,
    client.protocol,
    fn(request, on_event) { openai_api.stream(client, request, on_event) },
    explain,
    fn() { None },
    fn(_) { [] },
  )
}

fn config_decoder() {
  use base_url <- decode.field("baseUrl", decode.string)
  use api_key <- decode.field("apiKey", decode.string)
  decode.success(Config(base_url, api_key))
}
