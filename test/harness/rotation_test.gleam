// Account quota and capacity routing are stateful provider failures not exercised by scripted E2E responses.
import albedo/harness/extensions/alibaba/extension as alibaba
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should

const google_accounts = "{\"accounts\":{\"google-antigravity\":[{\"type\":\"oauth\",\"access\":\"a1\",\"refresh\":\"r1\",\"expires\":9999999999999,\"projectId\":\"p1\",\"email\":\"one@example.com\"},{\"type\":\"oauth\",\"access\":\"a2\",\"refresh\":\"r2\",\"expires\":9999999999999,\"projectId\":\"p2\",\"email\":\"two@example.com\"}]}}"

const quota = "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"You have exhausted your capacity on this model.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"QUOTA_EXHAUSTED\",\"metadata\":{\"quotaResetDelay\":\"2h3m4.5s\"}},{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"7384.5s\"}]}}"

const capacity = "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"No capacity available for model\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"MODEL_CAPACITY_EXHAUSTED\"}]}}"

fn request() -> types.Request {
  openai_api.request("gemini-3-flash", [types.User("hi")])
}

/// Answers 429 with `body` for the listed accounts and fails plainly for any
/// other, recording each account tried.
fn limited_stream(
  limited: List(String),
  body: String,
  tried: process.Subject(String),
  key: fn(account) -> String,
) -> fn(account, a, b) -> Result(c, types.Error) {
  fn(account, _request, _on_event) {
    process.send(tried, key(account))
    case list.contains(limited, key(account)) {
      True -> Error(types.HttpError(429, body))
      False -> Error(types.HttpError(500, "sibling answered"))
    }
  }
}

fn drain(tried: process.Subject(String), found: List(String)) -> List(String) {
  case process.receive(tried, 0) {
    Ok(token) -> drain(tried, [token, ..found])
    Error(_) -> list.reverse(found)
  }
}

fn no_wait(_: Int) -> Nil {
  panic as "a sibling had room; nothing should wait"
}

fn token(access: antigravity.Access) -> String {
  access.token
}

pub fn antigravity_sessions_spread_and_stick_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let pool = fn(session) {
    antigravity.pool(home, session, fn(_, _, _) { Error(types.Timeout) })
  }
  let assert Ok(first) = { pool("session-1") }.current()
  let assert Ok(again) = { pool("session-1") }.current()
  again |> should.equal(first)
  let assert Ok(other) = { pool("session-2") }.current()
  { other.token == first.token } |> should.be_false
  cleanup(root)
}

pub fn antigravity_quota_moves_the_request_to_a_sibling_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let tried = process.new_subject()
  let pool =
    antigravity.pool(
      home,
      "quota-session",
      limited_stream(["a1", "a2"], quota, tried, token),
    )
  let assert Ok(first) = pool.current()
  rotation.stream(
    pool,
    first,
    request(),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, fn(_) {
      panic as "a spent quota lasts hours; it must not be waited on"
    }),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(429, quota)))
  list.length(drain(tried, [])) |> should.equal(2)

  // Both accounts show their limit in /login, and the failure says so.
  let assert [one, two] = oauth.accounts(home, antigravity.login(google()))
  string.contains(one.detail, "limited until") |> should.be_true
  string.contains(two.detail, "limited until") |> should.be_true
  let assert Ok(last) = pool.current()
  let assert Some(message) =
    antigravity.explain(home, last, types.HttpError(429, quota))
  string.contains(message, "quota exhausted") |> should.be_true
  string.contains(message, "no other Google account") |> should.be_true
  cleanup(root)
}

pub fn antigravity_hands_off_when_one_account_is_spent_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let tried = process.new_subject()
  let pool =
    antigravity.pool(
      home,
      "handoff-session",
      limited_stream(["a1", "a2"], quota, tried, token),
    )
  let assert Ok(first) = pool.current()
  let pool =
    rotation.Pool(
      ..pool,
      stream: limited_stream([first.token], quota, tried, token),
    )
  rotation.stream(
    pool,
    first,
    request(),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, no_wait),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(500, "sibling answered")))
  let attempts = drain(tried, [])
  attempts |> list.length |> should.equal(2)
  list.first(attempts) |> should.equal(Ok(first.token))
  // The session now sticks to the sibling until the quota resets.
  let assert Ok(next) = pool.current()
  { next.token == first.token } |> should.be_false
  cleanup(root)
}

pub fn antigravity_capacity_waits_without_moving_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let tried = process.new_subject()
  let paused = process.new_subject()
  let pool =
    antigravity.pool(
      home,
      "capacity-session",
      limited_stream(["a1", "a2"], capacity, tried, token),
    )
  let assert Ok(first) = pool.current()
  rotation.stream(
    pool,
    first,
    request(),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, fn(delay) {
      process.send(paused, int.to_string(delay))
    }),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(429, capacity)))
  // Capacity is the model's, not the account's: the same account each time.
  drain(tried, []) |> list.unique |> should.equal([first.token])
  drain(paused, []) |> should.equal(["4000", "8000", "15000", "30000"])
  cleanup(root)
}

fn alibaba_config(a: String, b: String) -> String {
  "{\"providers\":{\"ali-a\":{\"extension\":\"alibaba\",\"baseUrl\":\"http://127.0.0.1:1/a\",\"apiKey\":\""
  <> a
  <> "\",\"protocol\":\"chat_completions\"},\"ali-b\":{\"extension\":\"alibaba\",\"baseUrl\":\"http://127.0.0.1:1/b\",\"apiKey\":\""
  <> b
  <> "\",\"protocol\":\"chat_completions\"},\"other\":{\"extension\":\"openai\",\"baseUrl\":\"http://x\",\"apiKey\":\"not-alibaba\"}}}"
}

fn api_key(client: types.Client) -> String {
  client.api_key
}

pub fn alibaba_rotates_to_another_profiles_key_test() -> Nil {
  let #(root, _, home) = fixture()
  let first_key = "ka-" <> int.to_string(unique())
  let second_key = "kb-" <> int.to_string(unique())
  let _ = write(home, "config.json", alibaba_config(first_key, second_key))
  let tried = process.new_subject()
  let body =
    "{\"error\":{\"message\":\"Allocated quota exceeded, please increase your quota limit.\",\"code\":\"Throttling.AllocationQuota\"}}"
  let pool = alibaba.pool(home, "ali-a", "ali-session")
  let assert Ok(first) = pool.current()
  first.api_key |> should.equal(first_key)
  first.base_url |> should.equal("http://127.0.0.1:1/a")
  rotation.stream(
    rotation.Pool(
      ..pool,
      stream: limited_stream([first_key], body, tried, api_key),
    ),
    first,
    openai_api.request("qwen3.8-max", [types.User("hi")]),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, no_wait),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(500, "sibling answered")))
  drain(tried, []) |> should.equal([first_key, second_key])
  // The limited key waits its turn; the sibling keeps its own base url.
  let assert Ok(next) = pool.current()
  next.api_key |> should.equal(second_key)
  next.base_url |> should.equal("http://127.0.0.1:1/b")
  cleanup(root)
}

fn google() -> antigravity.Endpoints {
  antigravity.Endpoints("http://127.0.0.1:1", "http://127.0.0.1:1", "")
}

@external(erlang, "erlang", "unique_integer")
fn unique() -> Int

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> String

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
