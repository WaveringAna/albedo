//// Google Vertex AI: Gemini models through Application Default Credentials.
//// A profile's `project` and `location` name the Vertex project and region,
//// falling back to `GOOGLE_VERTEX_PROJECT` and `GOOGLE_VERTEX_LOCATION`.
//// Credentials come from `GOOGLE_APPLICATION_CREDENTIALS` (or gcloud's
//// default path).

import albedo/daemon/configuration
import albedo/harness/extension
import albedo/harness/extensions/vertex/auth
import albedo/harness/extensions/vertex/stream
import albedo/harness/extensions/vertex/wire
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

type Config {
  Config(project: Option(String), location: Option(String))
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "vertex",
    "Application Default Credentials for Gemini models on Google Vertex AI",
    ["models"],
    [
      extension.ModelProviderPlugin(extension.ModelProvider(
        "google-vertex",
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- bool.guard(context.provider != "vertex", None)
  Some({
    use config <- result.try(configuration.settings(
      context.home,
      context.profile,
      config_decoder(),
    ))
    use #(project, location) <- result.try(location_config(config))
    Ok(extension.Upstream(
      wire.endpoint(location),
      types.ChatCompletions,
      fn(request, on_event) {
        use creds <- result.try(
          auth.load(credentials_path())
          |> result.map_error(types.InvalidRequest),
        )
        use token <- result.try(
          auth.access_token(creds) |> result.map_error(types.InvalidRequest),
        )
        use exchange <- result.try(wire.encode(
          token,
          project,
          location,
          request,
        ))
        openai_api.exchange(exchange, stream.reducer(), on_event)
      },
      explain,
      fn() { None },
      fn(_) { [] },
      types.any_images,
    ))
  })
}

fn explain(error: types.Error) -> Option(String) {
  case error {
    types.InvalidRequest(message) -> Some(message)
    _ -> None
  }
}

fn config_decoder() -> decode.Decoder(Config) {
  use project <- decode.optional_field(
    "project",
    None,
    decode.optional(decode.string),
  )
  use location <- decode.optional_field(
    "location",
    None,
    decode.optional(decode.string),
  )
  decode.success(Config(project, location))
}

/// The profile's project and location, else the environment's.
fn location_config(config: Config) -> Result(#(String, String), String) {
  case
    setting(config.project, "GOOGLE_VERTEX_PROJECT"),
    setting(config.location, "GOOGLE_VERTEX_LOCATION")
  {
    "", _ ->
      Error("Vertex needs a project: run /login or set GOOGLE_VERTEX_PROJECT")
    _, "" ->
      Error("Vertex needs a location: run /login or set GOOGLE_VERTEX_LOCATION")
    project, location -> Ok(#(project, location))
  }
}

fn setting(saved: Option(String), variable: String) -> String {
  case option.map(saved, string.trim) {
    Some(value) if value != "" -> value
    _ -> env(variable)
  }
}

fn credentials_path() -> String {
  case env("GOOGLE_APPLICATION_CREDENTIALS") {
    "" -> env("HOME") <> "/.config/gcloud/application_default_credentials.json"
    path -> path
  }
}

@external(erlang, "albedo_daemon", "env")
fn env(name: String) -> String
