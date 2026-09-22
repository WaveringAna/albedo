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

fn access_decoder() {
  use token <- decode.field("access", decode.string)
  use account_id <- decode.field("accountId", decode.string)
  decode.success(Access(token, account_id))
}

@external(erlang, "albedo_openai_auth", "codex_access")
fn native_access(home: String, session: String) -> Result(String, String)
