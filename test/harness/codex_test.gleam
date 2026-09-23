import albedo/daemon/configuration
import albedo/harness/extensions/codex/extension as codex
import albedo/openai_api
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

pub type Access {
  Access(token: String, account_id: String)
}

const credentials = "{\"openai-codex\":[{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0xIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTEifX0.s\",\"refresh\":\"refresh-1\",\"expires\":9999999999999,\"accountId\":\"account-1\",\"accountUserId\":\"seat-1\"},{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0yIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTIifX0.s\",\"refresh\":\"refresh-2\",\"expires\":9999999999999,\"accountId\":\"account-2\",\"accountUserId\":\"seat-2\"}]}"

const reversed_credentials = "{\"openai-codex\":[{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0yIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTIifX0.s\",\"refresh\":\"refresh-2\",\"expires\":9999999999999,\"accountId\":\"account-2\",\"accountUserId\":\"seat-2\"},{\"type\":\"oauth\",\"access\":\"h.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjb3VudC0xIiwiY2hhdGdwdF9hY2NvdW50X3VzZXJfaWQiOiJzZWF0LTEifX0.s\",\"refresh\":\"refresh-1\",\"expires\":9999999999999,\"accountId\":\"account-1\",\"accountUserId\":\"seat-1\"}]}"

pub fn sessions_stick_to_and_distribute_across_codex_accounts_test() {
  let #(root, _, home) = fixture()
  let _ = write(home, "auth.json", credentials)
  let first = access(home, "session-1")
  access(home, "session-1") |> should.equal(first)
  let accounts =
    [access(home, "session-1"), access(home, "session-2")]
    |> list.unique
  list.length(accounts) |> should.equal(2)
  cleanup(root)
}

pub fn session_pin_survives_credential_reordering_test() {
  let #(root, _, home) = fixture()
  let _ = write(home, "auth.json", credentials)
  let selected = access(home, "durable-session")
  let _ = write(home, "auth.json", reversed_credentials)
  access(home, "durable-session") |> should.equal(selected)
  cleanup(root)
}

pub fn revoked_codex_account_is_removed_test() {
  let #(root, _, home) = fixture()
  let _ = write(home, "auth.json", credentials)
  let #(revoked, client) = codex_client(home, "revoked-session")
  let assert Some(message) =
    codex.unauthorized(home, client, types.HttpError(401, "token_revoked"))
  string.ends_with(message, "run /login") |> should.be_true
  codex.unauthorized(home, client, types.HttpError(500, ""))
  |> should.equal(None)
  let remaining = access(home, "revoked-session")
  { remaining == revoked } |> should.be_false
  access(home, "another-session") |> should.equal(remaining)
  let #(_, last) = codex_client(home, "revoked-session")
  let assert Some(_) =
    codex.unauthorized(home, last, types.HttpError(401, "token_revoked"))
  let assert Error(_) = native_access(home, "revoked-session")
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

pub fn codex_profiles_require_responses_protocol_test() {
  let #(root, _, home) = fixture()
  let _ =
    write(
      home,
      "config.json",
      "{\"active\":\"bad\",\"providers\":{\"bad\":{\"extension\":\"codex\",\"model\":\"gpt-5.3-codex\",\"protocol\":\"chat_completions\"}}}",
    )
  let assert Error(_) = configuration.named(home, "bad")
  cleanup(root)
}
