//// Google Antigravity (Cloud Code Assist) OAuth provider. It translates
//// albedo requests and replay to Gemini's wire format over the OpenAI
//// transport, so history, projection, and tools stay provider-neutral.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/antigravity/catalog
import albedo/harness/extensions/antigravity/stream
import albedo/harness/extensions/antigravity/wire
import albedo/harness/oauth
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Access {
  Access(token: String, project: String, email: String)
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "antigravity",
    "Google Antigravity OAuth for Gemini 3 and Claude through Cloud Code Assist",
    [],
    [
      extension.LoginPlugin(login(google)),
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider(
        "antigravity",
        resolve,
      )),
    ],
    initialise,
  )
}

pub type Endpoints {
  Endpoints(token: String, userinfo: String, cloud_code: String)
}

const google = Endpoints(
  "https://oauth2.googleapis.com/token",
  "https://www.googleapis.com/oauth2/v1/userinfo?alt=json",
  catalog.endpoint,
)

/// The Antigravity IDE's Google sign-in. Its loopback port is not allowlisted
/// per port, so a busy 51121 moves to an ephemeral one.
pub fn login(endpoints: Endpoints) -> oauth.Login {
  oauth.Login(
    "antigravity",
    "add google antigravity account",
    "oauth · gemini 3, claude",
    types.ChatCompletions,
    "google-antigravity",
    oauth.Callback("127.0.0.1", 51_121, "/oauth-callback", False),
    authorize,
    fn(grant, code, progress) {
      native_exchange(code, grant.redirect, progress, endpoints)
    },
    native_account,
  )
}

fn authorize(grant: oauth.Grant) -> String {
  "https://accounts.google.com/o/oauth2/v2/auth?"
  <> uri.query_to_string([
    #("client_id", client_id()),
    #("response_type", "code"),
    #("redirect_uri", grant.redirect),
    #("scope", string.join(scopes, " ")),
    #("state", grant.state),
    #("access_type", "offline"),
    #("prompt", "consent"),
  ])
}

const scopes = [
  "https://www.googleapis.com/auth/cloud-platform",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/cclog",
  "https://www.googleapis.com/auth/experimentsandconfigs",
]

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  Ok(Nil)
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  case context.provider {
    "antigravity" ->
      Some({
        use encoded <- result.try(native_access(context.home))
        use access <- result.map(
          json.parse(encoded, access_decoder())
          |> result.replace_error("invalid Antigravity credential response"),
        )
        upstream(
          context.home,
          access,
          context.session,
          catalog.model(context.home, context.model, context.effort),
          user_agent(context.home),
        )
      })
    _ -> None
  }
}

pub fn upstream(
  home: String,
  access: Access,
  session: String,
  model: catalog.Model,
  user_agent: String,
) -> extension.Upstream {
  let context =
    wire.Context(access.token, access.project, session, model, user_agent)
  extension.Upstream(
    catalog.endpoint,
    types.ChatCompletions,
    fn(request, on_event) {
      let resolved_model =
        catalog.resolve_variant(home, model.id, request.options.effort)
      let resolved_context = wire.Context(..context, model: resolved_model)
      use exchange <- result.try(wire.encode(resolved_context, request))
      openai_api.exchange(exchange, stream.reducer(resolved_model), on_event)
    },
    explain(home, access, _),
  )
}

pub fn explain(
  home: String,
  access: Access,
  error: types.Error,
) -> Option(String) {
  let account = case access.email {
    "" -> "this Google account"
    email -> email
  }
  case error {
    types.HttpError(401, _) -> {
      native_expire(home, access.token)
      Some(
        "Antigravity rejected the sign-in for "
        <> account
        <> "; send your message again to refresh it, or run /login",
      )
    }
    types.HttpError(status, body) ->
      Some(case validation_url(body) {
        Ok(url) ->
          "Google requires account verification for "
          <> account
          <> ". Visit "
          <> url
          <> ", then send your message again"
        Error(_) ->
          "Cloud Code Assist API error ("
          <> int.to_string(status)
          <> "): "
          <> message(body)
      })
    _ -> None
  }
}

fn message(body: String) -> String {
  json.parse(body, decode.at(["error", "message"], decode.string))
  |> result.unwrap(body)
}

fn validation_url(body: String) -> Result(String, Nil) {
  let detail = {
    use reason <- decode.optional_field("reason", "", decode.string)
    use url <- decode.optional_field(
      "metadata",
      "",
      decode.optional_field("validation_url", "", decode.string, decode.success),
    )
    decode.success(#(reason, url))
  }
  json.parse(body, decode.at(["error", "details"], decode.list(detail)))
  |> result.replace_error(Nil)
  |> result.try(
    list.find_map(_, fn(detail) {
      case detail {
        #("VALIDATION_REQUIRED", url) if url != "" -> Ok(url)
        _ -> Error(Nil)
      }
    }),
  )
}

fn access_decoder() -> decode.Decoder(Access) {
  use token <- decode.field("access", decode.string)
  use project <- decode.field("projectId", decode.string)
  use email <- decode.optional_field("email", "", decode.string)
  decode.success(Access(token, project, email))
}

@external(erlang, "albedo_antigravity", "user_agent")
fn user_agent(home: String) -> String

@external(erlang, "albedo_antigravity", "expire")
fn native_expire(home: String, access: String) -> Nil

@external(erlang, "albedo_antigravity", "exchange")
fn native_exchange(
  code: String,
  redirect: String,
  progress: fn(String) -> Nil,
  endpoints: Endpoints,
) -> Result(json.Json, String)

@external(erlang, "albedo_antigravity", "account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_antigravity", "client_id")
fn client_id() -> String

@external(erlang, "albedo_antigravity", "access")
fn native_access(home: String) -> Result(String, String)
