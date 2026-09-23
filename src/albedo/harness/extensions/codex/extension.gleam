//// ChatGPT Codex subscription provider layered on the OpenAI transport.

import albedo/daemon/store
import albedo/harness/extension
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result

const base_url = "https://chatgpt.com/backend-api"

pub type Access {
  Access(token: String, account_id: String)
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "codex",
    "ChatGPT Plus/Pro OAuth for Codex models with session-sticky multi-account selection",
    ["openai"],
    [extension.ModelProviderPlugin(extension.ModelProvider("openai", resolve))],
    initialise,
  )
}

fn initialise(_ledger: store.Store) -> Result(Nil, String) {
  Ok(Nil)
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(types.Client, String)) {
  case context.provider {
    "codex" ->
      Some(
        native_access(context.home, context.session)
        |> result.try(fn(encoded) {
          json.parse(encoded, access_decoder())
          |> result.map_error(fn(_) { "invalid Codex credential response" })
        })
        |> result.map(fn(access) {
          openai_api.codex_client(
            base_url,
            access.token,
            access.account_id,
            context.session,
          )
        }),
      )
    _ -> None
  }
}

/// A 401 from the Codex backend means the ChatGPT sign-in was revoked or
/// expired server-side; refreshing cannot recover it. The account is removed
/// from auth.json and the message ends in "run /login", which clients treat
/// as a prompt to sign in again.
pub fn unauthorized(
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
    _, _ -> None
  }
}

fn access_decoder() {
  use token <- decode.field("access", decode.string)
  use account_id <- decode.field("accountId", decode.string)
  decode.success(Access(token, account_id))
}

@external(erlang, "albedo_openai_auth", "codex_access")
fn native_access(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_openai_auth", "codex_revoke")
fn native_revoke(home: String, access: String) -> Result(String, String)
