//// Claude subscription OAuth, using the Claude Code Messages API identity.

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
    "Claude Pro/Max via Claude Code OAuth and Anthropic Messages",
    ["models"],
    [
      extension.LoginPlugin(login()),
      extension.ModelsPlugin(extension.ModelCatalog(lookup, list_models)),
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
  use access <- result.try(native_access(context.home, context.session))
  use #(account, device, session) <- result.try(native_profile(
    access,
    context.session,
  ))
  Ok(extension.Upstream(
    endpoint,
    types.ChatCompletions,
    fn(request, on_event) {
      ensure_files(context.home, access, account, endpoint, request)
      use exchange <- result.try(wire.encode(
        context.home,
        access,
        account,
        device,
        session,
        request,
      ))
      let outcome =
        openai_api.exchange(
          exchange,
          stream.reducer(request.model, request.tools),
          on_event,
        )
      case outcome {
        // Drop cached file handles on 4xx so next turn heals inline.
        Error(types.HttpError(status, body)) if status >= 400 && status < 500 -> {
          reject_files(context.home, account, body)
          outcome
        }
        _ -> outcome
      }
    },
    fn(error) {
      case error {
        types.HttpError(401, _) -> {
          native_expire(context.home, access)
          Some(
            "Claude rejected this access token; send your message again to refresh it, or run /login",
          )
        }
        _ -> None
      }
    },
    // The OAuth profile's account UUID, not a credential.
    fn() { Some(account) },
    wire.cache_marks,
  ))
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
  access: String,
  account: String,
  endpoint: String,
  request: types.Request,
) -> Nil

@external(erlang, "albedo_claude_files", "reject")
fn reject_files(home: String, account: String, body: String) -> Nil

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
