// Account pins and 429 handoff depend on OAuth identities and provider responses unavailable in E2E.
import albedo/harness/extensions/codex/extension as codex
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub type Access {
  Access(token: String, account_id: String)
}

const credentials = "{\"accounts\":{\"openai-codex\":[{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0xIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTEifX0.s\",\"refresh\":\"refresh-1\",\"expires\":9999999999999,\"accountId\":\"account-1\",\"accountUserId\":\"seat-1\"},{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0yIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTIifX0.s\",\"refresh\":\"refresh-2\",\"expires\":9999999999999,\"accountId\":\"account-2\",\"accountUserId\":\"seat-2\"}]}}"

const reversed_credentials = "{\"accounts\":{\"openai-codex\":[{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0yIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTIifX0.s\",\"refresh\":\"refresh-2\",\"expires\":9999999999999,\"accountId\":\"account-2\",\"accountUserId\":\"seat-2\"},{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0xIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTEifX0.s\",\"refresh\":\"refresh-1\",\"expires\":9999999999999,\"accountId\":\"account-1\",\"accountUserId\":\"seat-1\"}]}}"

pub fn sessions_stick_to_and_distribute_across_codex_accounts_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let first = access(home, "session-1")
  access(home, "session-1") |> should.equal(first)
  let accounts =
    [access(home, "session-1"), access(home, "session-2")]
    |> list.unique
  list.length(accounts) |> should.equal(2)
  cleanup(root)
}

pub fn session_pin_survives_credential_reordering_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let selected = access(home, "durable-session")
  let _ = write(home, "creds.json", reversed_credentials)
  access(home, "durable-session") |> should.equal(selected)
  cleanup(root)
}

pub fn revoked_codex_account_is_removed_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let #(revoked, client) = codex_client(home, "revoked-session")
  let assert Some(message) =
    codex.account_failure(home, client, types.HttpError(401, "token_revoked"))
  string.ends_with(message, "run /login") |> should.be_true
  codex.account_failure(home, client, types.HttpError(500, ""))
  |> should.equal(None)
  let remaining = access(home, "revoked-session")
  { remaining == revoked } |> should.be_false
  access(home, "another-session") |> should.equal(remaining)
  let #(_, last) = codex_client(home, "revoked-session")
  let assert Some(_) =
    codex.account_failure(home, last, types.HttpError(401, "token_revoked"))
  let assert Error(_) = native_access(home, "revoked-session")
  cleanup(root)
}

pub fn usage_limit_moves_the_session_to_a_sibling_account_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let #(limited, client) = codex_client(home, "busy-session")

  // Ordinary rate limiting is transient and must not move the session.
  codex.account_failure(home, client, types.HttpError(429, "slow down"))
  |> should.equal(None)
  access(home, "busy-session") |> should.equal(limited)

  let body =
    "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_in_seconds\":3600}}"
  let assert Some(message) =
    codex.account_failure(home, client, types.HttpError(429, body))
  string.contains(message, "usage limit reached") |> should.be_true
  string.contains(message, "the next turn will use") |> should.be_true
  let next = access(home, "busy-session")
  { next == limited } |> should.be_false
  // Every session avoids the limited account while a sibling has usage.
  access(home, "fresh-session") |> should.equal(next)

  // With every account limited the message says so instead of naming one.
  let #(_, sibling) = codex_client(home, "busy-session")
  let assert Some(exhausted) =
    codex.account_failure(home, sibling, types.HttpError(429, body))
  string.contains(exhausted, "no other ChatGPT account") |> should.be_true
  cleanup(root)
}

/// Replays a stream where the named tokens answer 429 with `body` and every
/// other account fails plainly, recording which accounts were tried.
fn limited_stream(
  limited: List(String),
  body: String,
  tried: process.Subject(String),
) -> fn(types.Client, a, b) -> Result(c, types.Error) {
  fn(client: types.Client, _request, _on_event) {
    process.send(tried, client.api_key)
    case list.contains(limited, client.api_key) {
      True -> Error(types.HttpError(429, body))
      False -> Error(types.HttpError(500, "second account answered"))
    }
  }
}

fn rotate(
  home: String,
  session: String,
  first: types.Client,
  request: types.Request,
  stream: fn(types.Client, types.Request, fn(types.Event) -> types.Control) ->
    Result(types.Turn, types.Error),
  pause: fn(Int) -> Nil,
) -> Result(types.Turn, types.Error) {
  rotation.stream(
    codex.pool(home, session, stream),
    first,
    request,
    fn(_) { types.Continue },
    rotation.Budget(8, 0, pause),
    fn(_) { Nil },
  )
}

fn drain(tried: process.Subject(String), found: List(String)) -> List(String) {
  case process.receive(tried, 0) {
    Ok(token) -> drain(tried, [token, ..found])
    Error(_) -> list.reverse(found)
  }
}

pub fn a_limited_account_hands_the_same_request_to_the_next_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let #(_, first) = codex_client(home, "swarm-session")
  let tried = process.new_subject()
  let body =
    "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_in_seconds\":3600}}"
  let request = openai_api.request("gpt-5.5", [types.User("hi")])
  rotate(
    home,
    "swarm-session",
    first,
    request,
    limited_stream([first.api_key], body, tried),
    fn(_) { panic as "a sibling had room; nothing should wait" },
  )
  |> should.equal(Error(types.HttpError(500, "second account answered")))
  let attempts = drain(tried, [])
  list.length(attempts) |> should.equal(2)
  list.first(attempts) |> should.equal(Ok(first.api_key))
  cleanup(root)
}

pub fn a_burst_rate_limit_body_rotates_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let #(_, first) = codex_client(home, "burst-session")
  let tried = process.new_subject()
  let request = openai_api.request("gpt-6-luna", [types.User("hi")])
  rotate(
    home,
    "burst-session",
    first,
    request,
    limited_stream(
      [first.api_key],
      "{\"detail\":\"Rate limit exceeded\"}",
      tried,
    ),
    fn(_) { panic as "a sibling had room; nothing should wait" },
  )
  |> should.equal(Error(types.HttpError(500, "second account answered")))
  list.length(drain(tried, [])) |> should.equal(2)
  cleanup(root)
}

pub fn a_rate_limit_rotates_too_and_stops_when_all_are_busy_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let #(_, first) = codex_client(home, "busy-swarm")
  let tried = process.new_subject()
  let body =
    "{\"error\":{\"type\":\"rate_limit_exceeded\",\"resets_in_seconds\":20}}"
  let #(_, second) = codex_client(home, "other-busy-swarm")
  let both = list.unique([first.api_key, second.api_key])
  let request = openai_api.request("gpt-5.5", [types.User("hi")])
  let paused = process.new_subject()
  rotate(
    home,
    "busy-swarm",
    first,
    request,
    limited_stream(both, body, tried),
    fn(delay) { process.send(paused, int.to_string(delay)) },
  )
  |> should.equal(Error(types.HttpError(429, body)))
  // Each account once, then four waits with a retry after each, then it stops.
  list.length(drain(tried, [])) |> should.equal(6)
  drain(paused, []) |> should.equal(["4000", "8000", "15000", "30000"])
  cleanup(root)
}

pub fn a_usage_limit_on_every_account_does_not_wait_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let #(_, first) = codex_client(home, "spent-swarm")
  let #(_, second) = codex_client(home, "other-spent-swarm")
  let tried = process.new_subject()
  let body =
    "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_in_seconds\":3600}}"
  let request = openai_api.request("gpt-6-luna", [types.User("hi")])
  rotate(
    home,
    "spent-swarm",
    first,
    request,
    limited_stream(list.unique([first.api_key, second.api_key]), body, tried),
    fn(_) { panic as "a usage limit lasts hours; it must not be waited on" },
  )
  |> should.equal(Error(types.HttpError(429, body)))
  list.length(drain(tried, [])) |> should.equal(2)
  cleanup(root)
}

pub fn selected_account_overrides_the_session_pin_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", credentials)
  let pinned = access(home, "pinned-session")
  let other = case pinned {
    "account-1" -> "account-2"
    _ -> "account-1"
  }
  let _ =
    write(
      home,
      "creds.json",
      string.replace(
        credentials,
        "\"accountId\":\"" <> other <> "\"",
        "\"accountId\":\"" <> other <> "\",\"selected\":true",
      ),
    )
  access(home, "pinned-session") |> should.equal(other)
  access(home, "any-session") |> should.equal(other)
  cleanup(root)
}

fn codex_client(home: String, session: String) -> #(String, types.Client) {
  let assert Ok(encoded) = native_access(home, session)
  let decoder = {
    use token <- decode.field("access", decode.string)
    use account <- decode.field("accountId", decode.string)
    decode.success(#(token, account))
  }
  let assert Ok(#(token, account)) = json.parse(encoded, decoder)
  #(
    account,
    openai_api.codex_client("http://127.0.0.1", token, account, session),
  )
}

fn access(home: String, session: String) -> String {
  let assert Ok(encoded) = native_access(home, session)
  let decoder = {
    use account <- decode.field("accountId", decode.string)
    decode.success(account)
  }
  let assert Ok(account) = json.parse(encoded, decoder)
  account
}

@external(erlang, "albedo_openai_auth", "codex_access")
fn native_access(home: String, session: String) -> Result(String, String)

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
