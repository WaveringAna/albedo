//// Google Vertex AI: Gemini models through Application Default Credentials.
//// Fully environment-driven — `GOOGLE_VERTEX_PROJECT`, `GOOGLE_VERTEX_LOCATION`,
//// and `GOOGLE_APPLICATION_CREDENTIALS` (or gcloud's default path) — so a
//// profile needs only `"extension": "vertex"` and a Gemini model id.

import albedo/harness/extension
import albedo/harness/extensions/vertex/auth
import albedo/harness/extensions/vertex/stream
import albedo/harness/extensions/vertex/wire
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/option.{type Option, None, Some}
import gleam/result

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
    use #(project, location) <- result.try(location_config())
    Ok(extension.Upstream(
      "https://" <> location <> "-aiplatform.googleapis.com",
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

fn location_config() -> Result(#(String, String), String) {
  case env("GOOGLE_VERTEX_PROJECT"), env("GOOGLE_VERTEX_LOCATION") {
    "", _ -> Error("Vertex needs GOOGLE_VERTEX_PROJECT set")
    _, "" -> Error("Vertex needs GOOGLE_VERTEX_LOCATION set")
    project, location -> Ok(#(project, location))
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
