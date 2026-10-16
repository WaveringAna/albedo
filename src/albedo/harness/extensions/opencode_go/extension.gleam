//// OpenCode Go subscription provider over Chat Completions, Responses,
//// Anthropic Messages, and Gemini wire formats.

import albedo/harness/extension
import albedo/harness/extensions/claude/stream as claude_stream
import albedo/harness/extensions/opencode_go/catalog
import albedo/harness/extensions/opencode_go/wire
import albedo/harness/extensions/vertex/stream as vertex_stream
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const provider_name = "opencode-go"

pub fn extension() -> extension.Extension {
  extension.Extension(
    provider_name,
    "OpenCode Go subscription provider via OpenCode Console OAuth or API key for Qwen, GLM, Kimi, DeepSeek, MiMo, MiniMax, Claude, GPT, Grok, and Gemini models; a rate-limited key hands off to sibling accounts and keys",
    ["models"],
    [
      extension.LoginPlugin(login()),
      extension.ModelsPlugin(catalog.catalog()),
      extension.ModelProviderPlugin(extension.ModelProvider(
        provider_name,
        resolve,
      )),
    ],
    extension.no_initialise,
  )
}

pub fn login() -> oauth.Login {
  oauth.Login(
    provider_name,
    "add opencode go account",
    "oauth · qwen, glm, kimi, deepseek, mimo, minimax",
    oauth.Model,
    provider_name,
    oauth.Device(native_device_start),
    fn(_) { "" },
    fn(_, _, _) { Error("OpenCode Go uses device authorization") },
    native_account,
  )
}

fn resolve(
  context: extension.ModelContext,
) -> Option(Result(extension.Upstream, String)) {
  use <- rotation.require_provider(
    context,
    provider_name,
    "OpenCode Go",
    types.ChatCompletions,
  )
  let pool = pool(context.home, context.profile, context.session)
  use client <- result.map(pool.current())
  rotation.client_upstream(
    pool,
    client,
    fn(client, error) {
      explain_key(context.home, context.profile, client, error)
    },
    fn(client) { rotation.key_label(client.api_key) },
  )
}

/// Every OpenCode Go credential albedo can see, as a rotation pool: the profile's
/// own key or selected OAuth account first, then sibling opencode-go profiles,
/// creds.json's accounts, and the environment.
pub fn pool(
  home: String,
  profile: String,
  session: String,
) -> rotation.Pool(types.Client) {
  rotation.Pool(
    current: fn() { connect(home, profile, session) },
    mark: fn(client, body) {
      limited(home, profile, client, body) |> rotation.mark_limit
    },
    same: rotation.same_client,
    stream: stream,
    reject: fn(client) { native_expire(home, client.api_key) },
  )
}

pub fn stream(
  client: types.Client,
  request: types.Request,
  on_event: fn(types.Event) -> types.Control,
) -> Result(types.Turn, types.Error) {
  case wire.route(request.model) {
    wire.ChatRoute -> openai_api.stream(client, request, on_event)
    wire.ResponsesRoute -> {
      use exchange <- result.try(wire.encode_responses(client, request))
      openai_api.exchange(exchange, wire.responses_reducer(), on_event)
    }
    wire.MessagesRoute -> {
      use exchange <- result.try(wire.encode_messages(client, request))
      openai_api.exchange(
        exchange,
        claude_stream.reducer(request.model, request.tools),
        on_event,
      )
    }
    wire.GeminiRoute -> {
      use exchange <- result.try(wire.encode_gemini(client, request))
      openai_api.exchange(exchange, vertex_stream.reducer(), on_event)
    }
  }
}

fn connect(
  home: String,
  profile: String,
  session: String,
) -> Result(types.Client, String) {
  use #(base_url, api_key, org_id) <- result.try(native_access(
    home,
    profile,
    session,
  ))
  case base_url {
    "" -> Error("OpenCode Go base URL is invalid")
    _ -> {
      let session_id = case string.trim(session) {
        "" -> "opencode-go"
        id -> id
      }
      Ok(openai_api.opencode_go_client(base_url, api_key, session_id, org_id))
    }
  }
}

fn limited(
  home: String,
  profile: String,
  client: types.Client,
  body: String,
) -> Result(rotation.Limited, Nil) {
  native_limited(home, profile, client.api_key, body)
  |> result.replace_error(Nil)
}

/// A 429 reaching here has already been tried on every sibling key with room.
pub fn explain_key(
  home: String,
  profile: String,
  client: types.Client,
  error: types.Error,
) -> Option(String) {
  case error {
    types.HttpError(429, body) ->
      case limited(home, profile, client, body) {
        Ok(limit) if limit.next != "" ->
          Some(rotation.next_turn_message(
            "OpenCode Go limit reached until " <> limit.until,
            limit.next,
          ))
        _ -> explain(error)
      }
    _ -> explain(error)
  }
}

fn explain(error: types.Error) -> Option(String) {
  case error {
    types.HttpError(401, _) ->
      Some(
        "OpenCode Go rejected the credential; run /login to reconnect your OpenCode Go account or check OPENCODE_API_KEY",
      )
    types.HttpError(403, body) ->
      Some(with_detail("OpenCode Go access refused", body))
    types.HttpError(429, body) ->
      Some(with_detail("OpenCode Go request limit reached", body))
    types.HttpError(status, body) ->
      Some(with_detail(
        "OpenCode Go error (" <> int.to_string(status) <> ")",
        body,
      ))
    _ -> None
  }
}

fn with_detail(prefix: String, body: String) -> String {
  case string.trim(rotation.error_message(body)) {
    "" -> prefix
    detail -> prefix <> ": " <> detail
  }
}

@external(erlang, "albedo_opencode_go", "device_start")
fn native_device_start() -> Result(
  #(
    String,
    String,
    fn(fn(String) -> Nil) -> Result(Dict(String, Dynamic), String),
  ),
  String,
)

@external(erlang, "albedo_opencode_go", "account")
fn native_account(credential: Dynamic) -> oauth.Account

@external(erlang, "albedo_opencode_go", "expire")
fn native_expire(home: String, access: String) -> Nil

@external(erlang, "albedo_opencode_go", "access")
fn native_access(
  home: String,
  profile: String,
  session: String,
) -> Result(#(String, String, String), String)

@external(erlang, "albedo_opencode_go", "limited")
fn native_limited(
  home: String,
  profile: String,
  api_key: String,
  body: String,
) -> Result(rotation.Limited, String)
