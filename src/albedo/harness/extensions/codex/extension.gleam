//// ChatGPT Codex subscription provider layered on the OpenAI transport.

import albedo/harness/extension
import albedo/harness/extensions/codex/catalog
import albedo/harness/extensions/codex/search as codex_search
import albedo/harness/extensions/models/extension as models
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/harness/settings
import albedo/harness/web_search
import albedo/openai_api
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const base_url = "https://chatgpt.com/backend-api"

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann"

const scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

type Access {
  Access(token: String, account_id: String)
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "codex",
    "ChatGPT Plus/Pro OAuth for Codex models with selectable, session-sticky multi-account selection that skips accounts past their usage limit",
    ["openai"],
    [
      extension.ModelProviderPlugin(extension.ModelProvider("codex", resolve)),
      extension.LoginPlugin(login()),
      extension.ModelsPlugin(extension.ModelCatalog(
        lookup,
        list_models,
        Some(reload_models),
      )),
      extension.SearchPlugin(web_search.Provider("codex", "ChatGPT", search)),
    ],
    extension.no_initialise,
  )
}

/// What the ChatGPT backend reports about a model a Codex session uses;
/// models.dev fills in what it leaves out, such as the output limit.
fn lookup(
  model: String,
  endpoint: Option(String),
) -> Option(extension.ModelInfo) {
  let at = option.unwrap(endpoint, base_url)
  use <- bool.guard(!string.starts_with(at, base_url), None)
  catalog.lookup(settings.home(), at, model)
  |> option.map(models.complete_model(_, Some(at)))
}

/// The models the ChatGPT backend offers the selected account, refreshed
/// first when stale. Without a sign-in or a reachable backend, the last list
/// stays; with neither, the picker shows only the profile's own model.
fn list_models(provider: String, _endpoint: Option(String)) -> List(String) {
  case provider {
    "codex" -> {
      let home = settings.home()
      let _ =
        result.map(account(home, "", ""), fn(a) {
          catalog.refresh(home, a.token, a.account_id)
        })
      catalog.listed(home)
    }
    _ -> []
  }
}

/// Refetches the list `list_models` shows, for the same account.
fn reload_models() -> Result(Nil, String) {
  let home = settings.home()
  use a <- result.try(account(home, "", ""))
  catalog.reload(home, a.token, a.account_id)
}

/// `query` searched by the session's ChatGPT account, with the model the
/// `searchModel` setting names, else the account's first listed model.
fn search(query: web_search.Query) -> Result(web_search.Answer, String) {
  let home = settings.home()
  use access <- result.try(account(home, query.session, ""))
  use model <- result.try(search_model(home, access))
  // The Codex policy refuses a request without a session id.
  let session = case query.session {
    "" -> "web-search"
    session -> session
  }
  codex_search.run(client_for(access, session), model, query)
}

fn search_model(home: String, access: Access) -> Result(String, String) {
  use <- option.lazy_unwrap(
    web_search.configured_model("codex") |> option.map(Ok),
  )
  let _ = catalog.refresh(home, access.token, access.account_id)
  catalog.listed(home)
  |> list.first
  |> result.replace_error("ChatGPT lists no models for this account")
}

/// The Codex CLI browser flow. OpenAI allowlists the exact localhost:1455
/// redirect, so a busy port fails instead of moving.
fn login() -> oauth.Login {
  oauth.Login(
    "codex",
    "add chatgpt codex account",
    "oauth · supports multiple accounts",
    types.Responses,
    "openai-codex",
    oauth.Callback("localhost", 1455, "/auth/callback", True),
    fn(grant) {
      oauth.authorize_url("https://auth.openai.com/api/accounts/authorize", [
        #("response_type", "code"),
        #("client_id", client_id),
        #("redirect_uri", grant.redirect),
        #("scope", scope),
        #("code_challenge", grant.challenge),
        #("code_challenge_method", "S256"),
        #("state", grant.state),
        #("id_token_add_organizations", "true"),
        #("codex_cli_simplified_flow", "true"),
        #("originator", "albedo"),
      ])
    },
    fn(grant, code, _progress) {
      native_exchange(code, grant.verifier, grant.redirect)
    },
    native_account,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(context, "codex", "Codex", types.Responses)
  use access <- result.map(account(
    context.home,
    context.session,
    context.profile,
  ))
  // The list refreshes here, once per resolved session, and not in the rotation
  // pool: a pool reconnect is not a reason to reach the network again.
  catalog.refresh_later(context.home, access.token, access.account_id)
  rotation.client_upstream(
    profile_pool(
      context.home,
      context.session,
      context.profile,
      openai_api.stream,
    ),
    client_for(access, context.session),
    fn(client, error) { account_failure(context.home, client, error) },
    account_label,
  )
}

/// The ChatGPT account a client speaks for, or a hash of its key.
fn account_label(client: types.Client) -> String {
  case client.policy {
    types.Codex(account_id, _) -> account_id
    _ -> rotation.key_label(client.api_key)
  }
}

/// The session's current account as a client.
fn connect(
  home: String,
  session: String,
  profile: String,
) -> Result(types.Client, String) {
  account(home, session, profile) |> result.map(client_for(_, session))
}

fn client_for(access: Access, session: String) -> types.Client {
  openai_api.codex_client(base_url, access.token, access.account_id, session)
}

fn account(
  home: String,
  session: String,
  profile: String,
) -> Result(Access, String) {
  use encoded <- result.try(native_access(home, session, profile))
  json.parse(encoded, access_decoder())
  |> result.replace_error("invalid Codex credential response")
}

/// The ChatGPT accounts in creds.json as a rotation pool. A usage limit is
/// lasting; a rate limit, including the edge's burst answer, is brief.
pub fn pool(
  home: String,
  session: String,
  stream: fn(types.Client, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(types.Client) {
  profile_pool(home, session, "", stream)
}

fn profile_pool(
  home: String,
  session: String,
  profile: String,
  stream: fn(types.Client, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(types.Client) {
  rotation.Pool(
    current: fn() { connect(home, session, profile) },
    mark: fn(client, body) {
      limited(home, client, body) |> rotation.mark_limit
    },
    same: rotation.same_client,
    stream: stream,
  )
}

/// Records the limit a 429 reports against this client's account.
fn limited(
  home: String,
  client: types.Client,
  body: String,
) -> Result(rotation.Limited, Nil) {
  native_limited(home, client.api_key, body)
  |> result.replace_error(Nil)
  |> result.try(rotation.decode_limited)
}

/// Explains a Codex failure that changes which account should be used.
///
/// A 401 means the ChatGPT sign-in was revoked or expired server-side;
/// refreshing cannot recover it. The account is removed from creds.json and the
/// message ends in "run /login", which clients treat as a prompt to sign in again.
///
/// A limit 429 marks the account limited until its reset. By the time this
/// explains one, the rotation has already tried every sibling with room.
pub fn account_failure(
  home: String,
  client: types.Client,
  error: types.Error,
) -> Option(String) {
  case client.policy, error {
    types.Codex(_, _), types.HttpError(401, _) -> {
      let message = case native_revoke(home, client.api_key) {
        Ok("") -> "ChatGPT sign-in was revoked and has been removed"
        Ok(email) ->
          "ChatGPT sign-in for " <> email <> " was revoked and has been removed"
        Error(reason) ->
          "ChatGPT sign-in was revoked but could not be removed ("
          <> reason
          <> ")"
      }
      Some(message <> "; run /login")
    }
    types.Codex(_, _), types.HttpError(429, body) ->
      limited(home, client, body)
      |> option.from_result
      |> option.map(limit_message)
    _, _ -> None
  }
}

fn limit_message(limit: rotation.Limited) -> String {
  let account = case limit.account {
    "" -> "this ChatGPT account"
    account -> account
  }
  let kind = case limit.lasting {
    True -> "usage limit"
    False -> "rate limit"
  }
  rotation.limit_message(
    "ChatGPT " <> kind <> " reached for " <> account <> " until " <> limit.until,
    limit.next,
    "no other ChatGPT account has usage left. Add one with /login or wait for the reset",
  )
}

fn access_decoder() -> decode.Decoder(Access) {
  use token <- decode.field("access", decode.string)
  use account_id <- decode.field("accountId", decode.string)
  decode.success(Access(token, account_id))
}

@external(erlang, "albedo_openai_auth", "codex_exchange")
fn native_exchange(
  code: String,
  verifier: String,
  redirect: String,
) -> Result(json.Json, String)

@external(erlang, "albedo_openai_auth", "codex_account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_openai_auth", "codex_access")
fn native_access(
  home: String,
  session: String,
  profile: String,
) -> Result(String, String)

@external(erlang, "albedo_openai_auth", "codex_revoke")
fn native_revoke(home: String, access: String) -> Result(String, String)

@external(erlang, "albedo_openai_auth", "codex_limited")
fn native_limited(
  home: String,
  access: String,
  body: String,
) -> Result(String, String)
