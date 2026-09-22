import albedo/daemon/configuration
import gleam/dynamic/decode
import gleam/json
import gleam/list
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
