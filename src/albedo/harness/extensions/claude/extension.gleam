//// Claude over Anthropic Messages: a subscription through Claude Code OAuth,
//// or a Console API key set as the profile's `apiKey`.

import albedo/daemon/configuration
import albedo/harness/extension
import albedo/harness/extensions/claude/stream
import albedo/harness/extensions/claude/wire
import albedo/harness/extensions/models/extension as models
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

pub const endpoint = "https://api.anthropic.com"

const client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

const scope = "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"

/// Picker policy, not model metadata: only show requested current and fallback
/// tiers that models.dev actually lists for Anthropic.
const preferred = [
  "claude-opus-5-5", "claude-fable-5-1", "claude-sonnet-5", "claude-opus-5",
  "claude-opus-4-8", "claude-haiku-4-5",
]

pub fn extension() -> extension.Extension {
  extension.Extension(
    "claude",
    "Claude Pro/Max via Claude Code OAuth, or a Console API key, over Anthropic Messages",
    ["models"],
    [
      extension.LoginPlugin(login()),
      // models.dev is the list: its own catalog reloads it.
      extension.ModelsPlugin(extension.ModelCatalog(lookup, list_models, None)),
      extension.ModelProviderPlugin(extension.ModelProvider(
        "anthropic",
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

pub fn login() -> oauth.Login {
  oauth.Login(
    "claude",
    "add claude account",
    "oauth · claude pro/max",
    types.ChatCompletions,
    "anthropic",
    oauth.Callback("localhost", 53_692, "/callback", True),
    fn(grant) {
      oauth.authorize_url("https://claude.ai/oauth/authorize", [
        #("code", "true"),
        #("client_id", client_id),
        #("response_type", "code"),
        #("redirect_uri", grant.redirect),
        #("scope", scope),
        #("code_challenge", grant.challenge),
        #("code_challenge_method", "S256"),
        #("state", grant.state),
      ])
    },
    fn(grant, code, _progress) {
      native_exchange(code, grant.state, grant.verifier, grant.redirect)
    },
    native_account,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(
    context,
    "claude",
    "Claude",
    types.ChatCompletions,
  )
  use auth <- result.try(authenticate(context))
  let owner = wire.owner(auth)
  Ok(extension.Upstream(
    endpoint,
    types.ChatCompletions,
    fn(request, on_event) {
      ensure_files(
        context.home,
        wire.auth_header(auth),
        owner,
        endpoint,
        request,
      )
      use exchange <- result.try(wire.encode(context.home, auth, request))
      let outcome =
        openai_api.exchange(
          exchange,
          stream.reducer(request.model, request.tools),
          on_event,
        )
      case outcome {
        // Drop cached file handles on 4xx so next turn heals inline.
        Error(types.HttpError(status, body)) if status >= 400 && status < 500 -> {
          reject_files(context.home, owner, body)
          outcome
        }
        _ -> outcome
      }
    },
    fn(error) {
      case error, auth {
        types.HttpError(401, _), wire.Subscription(access:, ..) -> {
          native_expire(context.home, access)
          Some(
            "Claude rejected this access token; send your message again to refresh it, or run /login",
          )
        }
        types.HttpError(401, _), wire.ApiKey(_) ->
          Some(
            "Anthropic rejected this API key; check the profile's apiKey in config.json",
          )
        _, _ -> None
      }
    },
    fn() { Some(owner) },
    wire.cache_marks,
  ))
}

/// A profile's `apiKey` bills the Anthropic Console; without one, the signed-in
/// Claude subscription serves the session.
fn authenticate(context: extension.ModelContext) -> Result(wire.Auth, String) {
  let api_key =
    decode.optional_field("apiKey", "", decode.string, decode.success)
  case configuration.settings(context.home, context.profile, api_key) {
    Ok(key) if key != "" -> Ok(wire.ApiKey(key))
    _ -> {
      use access <- result.try(native_access(context.home, context.session))
      use #(account, device, session) <- result.map(native_profile(
        access,
        context.session,
      ))
      wire.Subscription(access, account, device, session)
    }
  }
}

fn list_models(provider: String, _endpoint: String) -> List(String) {
  case provider {
    "anthropic" -> {
      models.refresh()
      available_models(models.path())
    }
    _ -> []
  }
}

pub fn available_models(catalog: String) -> List(String) {
  let listed = models.list_at(catalog, "anthropic", "")
  list.filter(preferred, fn(id) { list.contains(listed, id) })
}

fn lookup(id: String, at: String) -> Option(extension.ModelInfo) {
  models.refresh()
  model_at(models.path(), id, at)
}

pub fn model_at(
  catalog: String,
  id: String,
  at: String,
) -> Option(extension.ModelInfo) {
  use <- bool.guard(
    !list.contains(preferred, id) || at != "" && at != endpoint,
    None,
  )
  use found <- option.map(models.lookup_provider_at(catalog, "anthropic", id))
  extension.ModelInfo(
    ..found,
    provider: "claude",
    input_modalities: list.filter(found.input_modalities, fn(mode) {
      mode == "text" || mode == "image"
    }),
    endpoint: Some(endpoint),
    environment: [],
  )
}

@external(erlang, "albedo_claude_files", "ensure")
fn ensure_files(
  home: String,
  auth: #(String, String),
  owner: String,
  endpoint: String,
  request: types.Request,
) -> Nil

@external(erlang, "albedo_claude_files", "reject")
fn reject_files(home: String, owner: String, body: String) -> Nil

@external(erlang, "albedo_claude_auth", "exchange")
fn native_exchange(
  code: String,
  state: String,
  verifier: String,
  redirect: String,
) -> Result(json.Json, String)

@external(erlang, "albedo_claude_auth", "account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_claude_auth", "expire")
fn native_expire(home: String, access: String) -> Nil

@external(erlang, "albedo_claude_auth", "profile")
fn native_profile(
  access: String,
  session: String,
) -> Result(#(String, String, String), String)

@external(erlang, "albedo_claude_auth", "access")
fn native_access(home: String, session: String) -> Result(String, String)
