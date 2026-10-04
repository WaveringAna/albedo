//// Amazon Bedrock: Claude models through the bedrock-runtime or
//// bedrock-mantle Messages route. `baseUrl` picks the host explicitly
//// (needed for mantle, or a non-default partition); left unset, it
//// defaults to bedrock-runtime in `AWS_REGION`/`AWS_DEFAULT_REGION`/the
//// active `AWS_PROFILE`'s own region. Auth is a saved profile's `apiKey`,
//// else `AWS_BEARER_TOKEN_BEDROCK`, else
//// `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`, else
//// `AWS_PROFILE`'s own `credential_process` or static keys. No sign-in
//// flow: create a profile with `"extension": "bedrock"` directly.

import albedo/clock
import albedo/daemon/configuration
import albedo/harness/extension
import albedo/harness/extensions/bedrock/aws_profile
import albedo/harness/extensions/bedrock/sigv4
import albedo/harness/extensions/bedrock/wire
import albedo/harness/extensions/claude/stream as claude_stream
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Config {
  Config(base_url: String, api_key: String)
}

/// Anthropic's own rule, not Bedrock's: once a request carries more than 20
/// images, every image in it must fit this edge. The same model family on
/// Bedrock gets the `claude` extension's declaration.
const images = types.ImageLimits(2000, Some(100))

pub fn extension() -> extension.Extension {
  extension.Extension(
    "bedrock",
    "AWS SigV4 or a Bedrock API key for Claude models on Amazon Bedrock (bedrock-runtime or bedrock-mantle)",
    ["models"],
    [
      extension.ModelProviderPlugin(extension.ModelProvider(
        "amazon-bedrock",
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- bool.guard(context.provider != "bedrock", None)
  Some({
    use config <- result.try(configuration.settings(
      context.home,
      context.profile,
      config_decoder(),
    ))
    use auth <- result.try(authenticate(config))
    use base_url <- result.try(effective_base_url(
      config.base_url,
      aws_profile.region(),
    ))
    Ok(extension.Upstream(
      base_url,
      types.ChatCompletions,
      fn(request, on_event) {
        use exchange <- result.try(wire.encode(
          auth,
          base_url,
          clock.system_seconds(),
          request,
        ))
        openai_api.exchange(
          exchange,
          claude_stream.reducer(request.model, request.tools),
          on_event,
        )
      },
      explain,
      fn() { None },
      fn(_) { [] },
      images,
    ))
  })
}

fn explain(error: types.Error) -> Option(String) {
  case error {
    types.InvalidRequest(message) -> Some(message)
    _ -> None
  }
}

/// `configured` as given, or — when blank — bedrock-runtime in `region`.
pub fn effective_base_url(
  configured: String,
  region: String,
) -> Result(String, String) {
  case string.trim(configured) {
    "" ->
      case region {
        "" ->
          Error(
            "Bedrock provider needs baseUrl or an AWS region (AWS_REGION, AWS_DEFAULT_REGION, or AWS_PROFILE's own region), e.g. https://bedrock-runtime.us-east-1.amazonaws.com",
          )
        region -> Ok("https://bedrock-runtime." <> region <> ".amazonaws.com")
      }
    base_url -> Ok(base_url)
  }
}

fn authenticate(config: Config) -> Result(wire.Auth, String) {
  case string.trim(config.api_key) {
    "" ->
      case env("AWS_BEARER_TOKEN_BEDROCK") {
        "" -> {
          let access = env("AWS_ACCESS_KEY_ID")
          let secret = env("AWS_SECRET_ACCESS_KEY")
          case access == "" || secret == "" {
            False ->
              Ok(wire.SigV4(sigv4.Credentials(access, secret, session_token())))
            True ->
              aws_profile.resolve()
              |> result.map(wire.SigV4)
              |> result.map_error(fn(reason) {
                "Bedrock credentials missing; set apiKey, AWS_BEARER_TOKEN_BEDROCK, AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY, or an AWS_PROFILE the daemon can resolve ("
                <> reason
                <> ")"
              })
          }
        }
        bearer -> Ok(wire.Bearer(bearer))
      }
    key -> Ok(wire.Bearer(key))
  }
}

fn session_token() -> Option(String) {
  case env("AWS_SESSION_TOKEN") {
    "" -> None
    value -> Some(value)
  }
}

fn config_decoder() -> decode.Decoder(Config) {
  use base_url <- decode.optional_field("baseUrl", "", decode.string)
  use api_key <- decode.optional_field("apiKey", "", decode.string)
  decode.success(Config(base_url, api_key))
}

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String
