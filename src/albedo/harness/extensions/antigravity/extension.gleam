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
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
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
    oauth.Model,
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
  let meter = catalog.meter_of_id(context.model)
  use access <- result.map(connect(
    context.home,
    context.session,
    context.profile,
    Some(meter),
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
  use access <- result.try(connect(home, query.session, "", Some("gemini")))
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

pub type Limited {
  Limited(
    account: String,
    until: String,
    next: String,
    lasting: Bool,
    meter: String,
    sibling_status: String,
    soon: Bool,
  )
}

/// The session's current account.
fn connect(
  home: String,
  session: String,
  profile: String,
  meter: Option(String),
) -> Result(Access, String) {
  native_access(home, session, profile, meter)
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
  let meter = catalog.meter(model)
  rotation.upstream(
    catalog.endpoint,
    types.ChatCompletions,
    profile_pool(
      home,
      session,
      profile,
      Some(meter),
      fn(access, request, on_event) {
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
        let send = fn(replay) {
          use exchange <- result.try(wire.encode_with(
            context,
            request,
            [],
            replay,
          ))
          openai_api.exchange(
            exchange,
            stream.reducer(resolved_model),
            on_event,
          )
        }
        // Earlier turns of another effort tier replay their signatures to
        // keep the cached prefix. Should Google ever refuse those, the
        // request goes once more with them sent portably.
        case send(wire.AcrossEfforts) {
          Error(types.HttpError(400, body)) as refused ->
            case
              wire.signature_refusal(body)
              && wire.crosses_efforts(context, request)
            {
              True -> send(wire.ExactVariant)
              False -> refused
            }
          outcome -> outcome
        }
      },
    ),
    access,
    fn(access, error) { explain_fallback(home, access, error, Some(meter)) },
    // The Google account's email; blank credentials report no account.
    fn(access) { access.email },
    case catalog.family(model) {
      catalog.Claude -> types.anthropic_images
      catalog.Gemini | catalog.GptOss -> types.any_images
    },
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
  profile_pool(home, session, "", None, stream)
}

pub fn pool_for_model(
  home: String,
  session: String,
  model: String,
  stream: fn(Access, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(Access) {
  profile_pool(home, session, "", Some(catalog.meter_of_id(model)), stream)
}

fn profile_pool(
  home: String,
  session: String,
  profile: String,
  meter: Option(String),
  stream: fn(Access, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(Access) {
  rotation.Pool(
    current: fn() { connect(home, session, profile, meter) },
    mark: fn(access, body) {
      case limited(home, access, body, meter) {
        Ok(limit) ->
          Some(rotation.Marked(
            case limit.lasting {
              True -> rotation.Lasting
              False -> rotation.Brief
            },
            room: limit.next != "",
          ))
        Error(_) -> None
      }
    },
    same: fn(a, b) { a.token == b.token },
    stream: stream,
  )
}

fn limited(
  home: String,
  access: Access,
  body: String,
  fallback_meter: Option(String),
) -> Result(Limited, Nil) {
  native_limited(home, access.token, body, fallback_meter)
  |> result.replace_error(Nil)
}

pub fn explain(
  home: String,
  access: Access,
  error: types.Error,
) -> Option(String) {
  explain_fallback(home, access, error, None)
}

fn explain_fallback(
  home: String,
  access: Access,
  error: types.Error,
  fallback_meter: Option(String),
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
      case limited(home, access, body, fallback_meter) {
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
fn limit_message(account: String, limit: Limited) -> String {
  let kind = case limit.lasting {
    True -> "quota exhausted"
    False -> "rate limited"
  }
  case limit.meter {
    "" ->
      rotation.limit_message(
        "Antigravity " <> kind <> " for " <> account <> " until " <> limit.until,
        limit.next,
        case limit.soon {
          True ->
            "no other Google account has room. Wait for the reset, or add an account with /login"
          False ->
            "no other Google account has room. Add one with /login or wait for the reset"
        },
      )
    meter -> {
      let title = case meter {
        "gemini" -> "Gemini"
        "claude" -> "Claude"
        "gpt-oss" -> "GPT-OSS"
        _ -> meter
      }
      let head =
        "Antigravity "
        <> title
        <> " "
        <> kind
        <> " for "
        <> account
        <> " until "
        <> limit.until
        <> " (its "
        <> meter
        <> " meter)"
      let none_left =
        "no other Google account has room on the "
        <> title
        <> " meter."
        <> limit.sibling_status
        <> case limit.soon {
          True -> " Wait for the reset, or add an account with /login"
          False -> " Add one with /login or wait for the reset"
        }
      rotation.limit_message(head, limit.next, none_left)
    }
  }
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
) -> Result(Dict(String, Dynamic), String)

@external(erlang, "albedo_antigravity", "account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_antigravity", "client_id")
fn client_id() -> String

@external(erlang, "albedo_antigravity", "access")
fn native_access(
  home: String,
  session: String,
  profile: String,
  meter: Option(String),
) -> Result(Access, String)

@external(erlang, "albedo_antigravity", "limited")
fn native_limited(
  home: String,
  access: String,
  body: String,
  fallback_meter: Option(String),
) -> Result(Limited, String)
