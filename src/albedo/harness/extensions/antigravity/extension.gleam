//// Google Antigravity (Cloud Code Assist) OAuth provider. It translates
//// albedo requests and replay to Gemini's wire format over the OpenAI
//// transport, so history, projection, and tools stay provider-neutral.

import albedo/harness/extension
import albedo/harness/extensions/antigravity/catalog
import albedo/harness/extensions/antigravity/errors
import albedo/harness/extensions/antigravity/search as antigravity_search
import albedo/harness/extensions/antigravity/stream
import albedo/harness/extensions/antigravity/wire
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/harness/settings
import albedo/harness/web_search
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

pub type Access {
  Access(token: String, project: String, email: String)
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "antigravity",
    "Google Antigravity OAuth for Gemini 3 and Claude through Cloud Code Assist, with session-sticky multi-account selection that moves past rate limits and spent quotas",
    [],
    [
      extension.LoginPlugin(login(google)),
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider(
        "antigravity",
        resolve,
      )),
      extension.SearchPlugin(web_search.Provider(
        "antigravity",
        "Gemini",
        search,
      )),
    ],
    extension.no_initialise,
  )
}

pub type Endpoints {
  Endpoints(token: String, userinfo: String, cloud_code: String)
}

const google =
  Endpoints(
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
    fn(grant) {
      oauth.authorize_url("https://accounts.google.com/o/oauth2/v2/auth", [
        #("client_id", client_id()),
        #("response_type", "code"),
        #("redirect_uri", grant.redirect),
        #("scope", string.join(scopes, " ")),
        #("state", grant.state),
        #("access_type", "offline"),
        #("prompt", "consent"),
      ])
    },
    fn(grant, code, progress) {
      native_exchange(code, grant.redirect, progress, endpoints)
    },
    native_account,
  )
}

const scopes = [
  "https://www.googleapis.com/auth/cloud-platform",
  "https://www.googleapis.com/auth/userinfo.email",
  "https://www.googleapis.com/auth/userinfo.profile",
  "https://www.googleapis.com/auth/cclog",
  "https://www.googleapis.com/auth/experimentsandconfigs",
]

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(
    context,
    "antigravity",
    "Antigravity",
    types.ChatCompletions,
  )
  use access <- result.map(connect(
    context.home,
    context.session,
    context.profile,
  ))
  upstream(
    context.home,
    access,
    context.session,
    context.profile,
    catalog.model(context.home, context.model, context.effort),
    user_agent(context.home),
  )
}

/// `query` searched by the session's Google account, with the model the
/// `searchModel` setting names, else the first listed Gemini model, at its
/// lowest effort.
fn search(query: web_search.Query) -> Result(web_search.Answer, String) {
  let home = settings.home()
  // Signed out fails here, before listing models can reach the network.
  use access <- result.try(connect(home, query.session, ""))
  use model <- result.try(case web_search.configured_model("antigravity") {
    Some(model) -> Ok(model)
    None ->
      catalog.catalog().list("antigravity", None)
      |> list.find(string.starts_with(_, "gemini"))
      |> result.replace_error("Antigravity lists no Gemini model")
  })
  antigravity_search.run(
    wire.Context(
      access.token,
      access.project,
      query.session,
      catalog.model(home, model, Some("low")),
      user_agent(home),
    ),
    query,
  )
}

/// The session's current account.
fn connect(
  home: String,
  session: String,
  profile: String,
) -> Result(Access, String) {
  use encoded <- result.try(native_access(home, session, profile))
  json.parse(encoded, access_decoder())
  |> result.replace_error("invalid Antigravity credential response")
}

/// Streams on `access`, and on sibling Google accounts when it hits a limit.
fn upstream(
  home: String,
  access: Access,
  session: String,
  profile: String,
  model: catalog.Model,
  user_agent: String,
) -> extension.Upstream {
  rotation.upstream(
    catalog.endpoint,
    types.ChatCompletions,
    profile_pool(home, session, profile, fn(access, request, on_event) {
      let resolved_model =
        catalog.resolve_variant(home, model.id, request.options.effort)
      let context =
        wire.Context(
          access.token,
          access.project,
          session,
          resolved_model,
          user_agent,
        )
      use exchange <- result.try(wire.encode(context, request))
      openai_api.exchange(exchange, stream.reducer(resolved_model), on_event)
    }),
    access,
    fn(access, error) { explain(home, access, error) },
    // The Google account's email; blank credentials report no account.
    fn(access) { access.email },
  )
}

/// The Google accounts in creds.json as a rotation pool. A spent quota is
/// lasting; a rate limit is brief. A model out of capacity for everyone is not
/// an account's limit, so it waits without moving the session.
pub fn pool(
  home: String,
  session: String,
  stream: fn(Access, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(Access) {
  profile_pool(home, session, "", stream)
}

fn profile_pool(
  home: String,
  session: String,
  profile: String,
  stream: fn(Access, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(Access) {
  rotation.Pool(
    current: fn() { connect(home, session, profile) },
    mark: fn(access, body) {
      limited(home, access, body) |> rotation.mark_limit
    },
    same: fn(a, b) { a.token == b.token },
    stream: stream,
  )
}

fn limited(
  home: String,
  access: Access,
  body: String,
) -> Result(rotation.Limited, Nil) {
  native_limited(home, access.token, body)
  |> result.replace_error(Nil)
  |> result.try(rotation.decode_limited)
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
    types.HttpError(429, body) ->
      case limited(home, access, body) {
        Ok(limit) -> Some(limit_message(account, limit))
        Error(_) ->
          Some(
            "Cloud Code Assist API error (429): "
            <> rotation.error_message(body),
          )
      }
    types.HttpError(status, body) ->
      Some(case errors.verification_url(body) {
        Ok(url) if url != "" ->
          "Google requires account verification for "
          <> account
          <> ". Visit "
          <> url
          <> ", then send your message again"
        _ ->
          "Cloud Code Assist API error ("
          <> int.to_string(status)
          <> "): "
          <> rotation.error_message(body)
      })
    _ -> None
  }
}

/// By the time this explains a limit, the rotation has already tried every
/// sibling with room.
fn limit_message(account: String, limit: rotation.Limited) -> String {
  let kind = case limit.lasting {
    True -> "quota exhausted"
    False -> "rate limited"
  }
  rotation.limit_message(
    "Antigravity " <> kind <> " for " <> account <> " until " <> limit.until,
    limit.next,
    "no other Google account has room. Add one with /login or wait for the reset",
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
fn native_access(
  home: String,
  session: String,
  profile: String,
) -> Result(String, String)

@external(erlang, "albedo_antigravity", "limited")
fn native_limited(
  home: String,
  access: String,
  body: String,
) -> Result(String, String)
