//// Generic OpenAI-compatible provider authentication and client construction.

import albedo/daemon/configuration
import albedo/harness/extension
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Config {
  Config(base_url: String, api_key: String, image_edge: Int)
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
      False if config.image_edge < 1 ->
        Error("imageEdge in config.json must be a positive number of pixels")
      False -> {
        let upstream =
          openai_api.client(context.protocol, config.base_url, config.api_key)
          |> upstream(fn(_) { None })
        let images =
          types.ImageLimits(
            int.min(config.image_edge, types.max_image_edge),
            None,
          )
        Ok(extension.Upstream(..upstream, images:))
      }
    }
  })
}

/// An upstream served by the shared OpenAI stream.
fn upstream(
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
    types.any_images,
  )
}

fn config_decoder() -> decode.Decoder(Config) {
  use base_url <- decode.field("baseUrl", decode.string)
  use api_key <- decode.field("apiKey", decode.string)
  // An endpoint that takes smaller images than albedo's own bound says so, and
  // images over it are refused or scaled like they are for Claude.
  use image_edge <- decode.optional_field(
    "imageEdge",
    types.max_image_edge,
    decode.int,
  )
  decode.success(Config(base_url, api_key, image_edge))
}
