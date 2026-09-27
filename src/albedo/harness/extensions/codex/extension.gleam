//// ChatGPT Codex subscription provider layered on the OpenAI transport.

import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions/codex/catalog
import albedo/harness/extensions/models/extension as models
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/harness/settings
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

const base_url = "https://chatgpt.com/backend-api"

const client_id = "app_EMoamEEZ73f0CkXaXp7hrann"

const scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"

pub type Access {
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
      extension.ModelsPlugin(extension.ModelCatalog(lookup, list_models)),
    ],
    initialise,
  )
}

/// What the ChatGPT backend reports about a model a Codex session uses;
/// models.dev fills in what it leaves out, such as the output limit.
fn lookup(model: String, endpoint: String) -> Option(extension.ModelInfo) {
  case string.starts_with(endpoint, base_url) {
    True ->
      catalog.lookup(settings.home(), endpoint, model)
      |> option.map(models.complete_model(_, endpoint))
    False -> None
  }
}

/// The models the ChatGPT backend offers the selected account, refreshed
/// first when stale. Without a sign-in or a reachable backend, the last list
/// stays; with neither, the picker shows only the profile's own model.
fn list_models(provider: String, _endpoint: String) -> List(String) {
  case provider {
    "codex" -> {
      let home = settings.home()
      let _ = case account(home, "") {
        Ok(access) -> catalog.refresh(home, access.token, access.account_id)
        Error(error) -> Error(error)
      }
      catalog.listed(home)
    }
    _ -> []
  }
}

/// The Codex CLI browser flow. OpenAI allowlists the exact localhost:1455
/// redirect, so a busy port fails instead of moving.
pub fn login() -> oauth.Login {
  oauth.Login(
    "codex",
    "add chatgpt codex account",
    "oauth · supports multiple accounts",
    types.Responses,
    "openai-codex",
    oauth.Callback("localhost", 1455, "/auth/callback", True),
    authorize,
    fn(grant, code, _progress) {
      native_exchange(code, grant.verifier, grant.redirect)
    },
    native_account,
  )
}

fn authorize(grant: oauth.Grant) -> String {
  "https://auth.openai.com/api/accounts/authorize?"
  <> uri.query_to_string([
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
}

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  Ok(Nil)
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  case context.provider {
    "codex" ->
      case context.protocol {
        types.Responses ->
          Some(
            connect(context.home, context.session)
            |> result.map(fn(client) {
              rotation.upstream(
                client.base_url,
                client.protocol,
                pool(context.home, context.session, openai_api.stream),
                client,
                fn(client, error) {
                  account_failure(context.home, client, error)
                },
              )
            }),
          )
        _ -> Some(Error("Codex provider requires the responses protocol"))
      }
    _ -> None
  }
}

/// The session's current account as a client. Its model list refreshes in
/// the background, so a new model shows up without a picker visit.
fn connect(home: String, session: String) -> Result(types.Client, String) {
  use access <- result.map(account(home, session))
  catalog.refresh_later(home, access.token, access.account_id)
  openai_api.codex_client(base_url, access.token, access.account_id, session)
}

fn account(home: String, session: String) -> Result(Access, String) {
  native_access(home, session)
  |> result.try(fn(encoded) {
    json.parse(encoded, access_decoder())
    |> result.map_error(fn(_) { "invalid Codex credential response" })
  })
}

/// The ChatGPT accounts in auth.json as a rotation pool. A usage limit is
/// lasting; a rate limit, including the edge's burst answer, is brief.
pub fn pool(
  home: String,
  session: String,
  stream: fn(types.Client, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
) -> rotation.Pool(types.Client) {
  rotation.Pool(
    current: fn() { connect(home, session) },
    mark: fn(client, body) {
      limited(home, client, body)
      |> option.from_result
      |> option.map(fn(limit) {
        rotation.marked(limit.lasting, limit.next != "")
      })
    },
    same: fn(a: types.Client, b: types.Client) { a.api_key == b.api_key },
    stream: stream,
  )
}

type Limited {
  Limited(account: String, until: String, next: String, lasting: Bool)
}

/// Records the limit a 429 reports against this client's account.
fn limited(
  home: String,
  client: types.Client,
  body: String,
) -> Result(Limited, Nil) {
  native_limited(home, client.api_key, body)
  |> result.replace_error(Nil)
  |> result.try(fn(encoded) {
    json.parse(encoded, limit_decoder()) |> result.replace_error(Nil)
  })
}

/// Explains a Codex failure that changes which account should be used.
///
/// A 401 means the ChatGPT sign-in was revoked or expired server-side;
/// refreshing cannot recover it. The account is removed from auth.json and the
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

fn limit_message(limit: Limited) -> String {
  let account = case limit.account {
    "" -> "this ChatGPT account"
    account -> account
  }
  let kind = case limit.lasting {
    True -> "usage limit"
    False -> "rate limit"
  }
  let head =
    "ChatGPT " <> kind <> " reached for " <> account <> " until " <> limit.until
  case limit.next {
    "" ->
      head
      <> "; no other ChatGPT account has usage left. Add one with /login or wait for the reset"
    next ->
      head
      <> "; the next turn will use "
      <> next
      <> ". Send your message again to continue"
  }
}

fn limit_decoder() {
  use account <- decode.field("account", decode.string)
  use until <- decode.field("until", decode.string)
  use next <- decode.field("next", decode.string)
  use lasting <- decode.optional_field("lasting", True, decode.bool)
  decode.success(Limited(account, until, next, lasting))
}

fn access_decoder() {
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
fn native_access(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_openai_auth", "codex_revoke")
fn native_revoke(home: String, access: String) -> Result(String, String)

@external(erlang, "albedo_openai_auth", "codex_limited")
fn native_limited(
  home: String,
  access: String,
  body: String,
) -> Result(String, String)
