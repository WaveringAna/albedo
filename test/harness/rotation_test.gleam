//// Account quota, capacity routing, and exact pool ordering require provider
//// limit states and captured clocks the E2E fake provider cannot reproduce.

import albedo/clock
import albedo/harness/accounts
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/alibaba/extension as alibaba
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/extensions/opencode_go/extension as opencode_go
import albedo/harness/extensions/opencode_go/wire as opencode_go_wire
import albedo/harness/extensions/vertex/stream as vertex_stream
import albedo/harness/oauth
import albedo/harness/rotation
import albedo/openai_api
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

const google_accounts =
  "{\"accounts\":{\"google-antigravity\":[{\"type\":\"oauth\",\"access\":\"a1\",\"refresh\":\"r1\",\"expires\":9999999999999,\"projectId\":\"p1\",\"email\":\"one@example.com\"},{\"type\":\"oauth\",\"access\":\"a2\",\"refresh\":\"r2\",\"expires\":9999999999999,\"projectId\":\"p2\",\"email\":\"two@example.com\"}]}}"

/// The same two accounts, with the public ids a pinned profile names.
const pinned_accounts =
  "{\"accounts\":{\"google-antigravity\":[{\"type\":\"oauth\",\"_albedo_account_id\":\"public-one\",\"access\":\"a1\",\"refresh\":\"r1\",\"expires\":9999999999999,\"projectId\":\"p1\",\"email\":\"one@example.com\"},{\"type\":\"oauth\",\"_albedo_account_id\":\"public-two\",\"access\":\"a2\",\"refresh\":\"r2\",\"expires\":9999999999999,\"projectId\":\"p2\",\"email\":\"two@example.com\"}]}}"

const pinned_config =
  "{\"providers\":{\"pinned\":{\"accountId\":\"public-one\"}}}"

const claude_quota =
  "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"You have exhausted your capacity on this model.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"QUOTA_EXHAUSTED\",\"metadata\":{\"model\":\"claude-sonnet-5-5-high\",\"quotaResetDelay\":\"2h3m4.5s\"}},{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"7384.5s\"}]}}"

const gemini_quota =
  "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"You have exhausted your capacity on this model.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"QUOTA_EXHAUSTED\",\"metadata\":{\"model\":\"gemini-3.8-flash-medium\",\"quotaResetDelay\":\"2h3m4.5s\"}},{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"7384.5s\"}]}}"

const week_quota =
  "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"Individual quota reached.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"QUOTA_EXHAUSTED\",\"metadata\":{\"quotaResetDelay\":\"142h\"}}]}}"

const quota =
  "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"You have exhausted your capacity on this model.\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"QUOTA_EXHAUSTED\",\"metadata\":{\"quotaResetDelay\":\"2h3m4.5s\"}},{\"@type\":\"type.googleapis.com/google.rpc.RetryInfo\",\"retryDelay\":\"7384.5s\"}]}}"

const capacity =
  "{\"error\":{\"code\":429,\"status\":\"RESOURCE_EXHAUSTED\",\"message\":\"No capacity available for model\",\"details\":[{\"@type\":\"type.googleapis.com/google.rpc.ErrorInfo\",\"reason\":\"MODEL_CAPACITY_EXHAUSTED\"}]}}"

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

/// A request racing a cache's expiry, such as a warming ping, gives up at
/// its first limit: a sibling or a wait would land it after the cache is gone.
pub fn an_impatient_request_neither_hops_nor_waits_test() -> Nil {
  let tried = process.new_subject()
  let pool =
    rotation.Pool(
      current: fn() { Ok("a2") },
      mark: fn(_, _) { Some(rotation.Marked(rotation.Brief, True)) },
      same: fn(a, b) { a == b },
      stream: limited_stream(["a1", "a2"], capacity, tried, fn(account) {
        account
      }),
      reject: fn(_) { Nil },
    )
  let upstream =
    rotation.upstream(
      "https://cloudcode.example",
      types.ChatCompletions,
      pool,
      "a1",
      fn(_, _) { None },
      fn(account) { account },
      types.any_images,
    )
  let ping =
    types.Request(
      ..request(),
      options: types.Options(..types.defaults, patient: False),
    )
  upstream.stream(ping, fn(_) { types.Continue })
  |> should.equal(Error(types.HttpError(429, capacity)))
  drain(tried, []) |> should.equal(["a1"])
}

pub fn antigravity_sessions_spread_and_stick_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let pool = fn(session) {
    antigravity.pool(home, session, fn(_, _, _) {
      Error(types.Timeout(types.Connecting, 1))
    })
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
    rotation.Budget(
      8,
      0,
      fn(_) { panic as "a spent quota lasts hours; it must not be waited on" },
      False,
    ),
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
    antigravity.explain(home, "", last, types.HttpError(429, quota))
  string.contains(message, "quota exhausted") |> should.be_true
  string.contains(message, "no other Google account") |> should.be_true
  cleanup(root)
}

/// A reset that is hours away is named by how long it takes and leads with
/// waiting; one that is days away still points at adding an account first.
pub fn antigravity_limit_text_says_how_long_a_near_reset_takes_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let explain_after = fn(session, body) {
    let tried = process.new_subject()
    let pool =
      antigravity.pool(
        home,
        session,
        limited_stream(["a1", "a2"], body, tried, token),
      )
    let assert Ok(first) = pool.current()
    let _ =
      rotation.stream(
        pool,
        first,
        request(),
        fn(_) { types.Continue },
        rotation.Budget(8, 0, no_wait, False),
        fn(_) { Nil },
      )
    let assert Ok(last) = pool.current()
    let assert Some(message) =
      antigravity.explain(home, "", last, types.HttpError(429, body))
    message
  }

  let soon = explain_after("soon-session", quota)
  string.contains(soon, "(in 2h") |> should.be_true
  string.contains(soon, "Wait for the reset, or add an account with /login")
  |> should.be_true
  string.contains(soon, "Add one with /login") |> should.be_false

  let far = explain_after("far-session", week_quota)
  string.contains(far, "(in ") |> should.be_false
  string.contains(far, "Add one with /login or wait for the reset")
  |> should.be_true
  cleanup(root)
}

/// A profile pinned to one account cannot rotate to its sibling, so a 429 on
/// it must not invite the user to resend: the same account would answer again.
pub fn antigravity_pinned_profile_names_its_account_instead_of_a_sibling_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", pinned_accounts)
  let _ = write(home, "config.json", pinned_config)
  let one = antigravity.Access("a1", "p1", "one@example.com")
  let assert Some(message) =
    antigravity.explain(home, "pinned", one, types.HttpError(429, gemini_quota))
  string.contains(message, "pinned to one@example.com") |> should.be_true
  string.contains(message, "two@example.com") |> should.be_false
  string.contains(message, "next turn will use") |> should.be_false
  string.contains(message, "Send your message again") |> should.be_false
  cleanup(root)

  // Unpinned, the same 429 does hand the next turn to the sibling.
  let #(free_root, _, free_home) = fixture()
  let _ = write(free_home, "creds.json", pinned_accounts)
  let assert Some(open) =
    antigravity.explain(free_home, "", one, types.HttpError(429, gemini_quota))
  string.contains(open, "pinned to") |> should.be_false
  string.contains(open, "next turn will use two@example.com") |> should.be_true
  cleanup(free_root)
}

/// Claude behind Cloud Code Assist is held to Anthropic's 2000px rule, so an
/// oversized image is fitted before the request rather than refused after it.
pub fn antigravity_claude_quota_leaves_gemini_served_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let tried = process.new_subject()
  let claude_pool =
    antigravity.pool_for_model(
      home,
      "claude-session",
      "claude-sonnet-4-6",
      limited_stream(["a1"], claude_quota, tried, token),
    )
  let assert Ok(first) = claude_pool.current()
  first.token |> should.equal("a1")

  // Account a1 hits a Claude 429 and hops to sibling a2.
  rotation.stream(
    claude_pool,
    first,
    openai_api.request("claude-sonnet-4-6", [types.User("hi")]),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, no_wait, False),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(500, "sibling answered")))
  let attempts = drain(tried, [])
  attempts |> should.equal(["a1", "a2"])

  // Claude requests now treat a1 as limited and stick to a2.
  let assert Ok(claude_next) = claude_pool.current()
  claude_next.token |> should.equal("a2")

  // But Gemini requests on the same session/account are NOT walled: a1 still serves Gemini!
  let gemini_pool =
    antigravity.pool_for_model(home, "gemini-1", "gemini-3-flash", fn(_, _, _) {
      Error(types.Timeout(types.Connecting, 1))
    })
  let assert Ok(gemini_served) = gemini_pool.current()
  gemini_served.token |> should.equal("a1")

  // /login shows a1 is limited specifically on Claude.
  let assert [one, two] = oauth.accounts(home, antigravity.login(google()))
  string.contains(one.detail, "limited on Claude until") |> should.be_true
  string.contains(two.detail, "limited on Claude until") |> should.be_false

  // When all accounts exhaust their Claude quota, explain names the Claude meter.
  let both_tried = process.new_subject()
  let both_claude_pool =
    antigravity.pool_for_model(
      home,
      "both-claude-session",
      "claude-sonnet-4-6",
      limited_stream(["a1", "a2"], claude_quota, both_tried, token),
    )
  let assert Ok(c1) = both_claude_pool.current()
  rotation.stream(
    both_claude_pool,
    c1,
    openai_api.request("claude-sonnet-4-6", [types.User("hi")]),
    fn(_) { types.Continue },
    rotation.Budget(
      8,
      0,
      fn(_) { panic as "a spent quota lasts hours; it must not be waited on" },
      False,
    ),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(429, claude_quota)))
  let assert Ok(last) = both_claude_pool.current()
  let assert Some(claude_msg) =
    antigravity.explain(home, "", last, types.HttpError(429, claude_quota))
  string.contains(claude_msg, "Antigravity Claude quota exhausted")
  |> should.be_true
  string.contains(claude_msg, "its claude meter") |> should.be_true
  string.contains(
    claude_msg,
    "no other Google account has room on the Claude meter",
  )
  |> should.be_true

  // Both a1 and a2 are now limited on Claude. When a2 also exhausts Gemini, and
  // then a1 exhausts Gemini, no accounts have room on Gemini, and refusal message names
  // the Gemini meter while mentioning sibling a2's Claude limit.
  let assert Some(_) =
    antigravity.explain(
      home,
      "",
      claude_next,
      types.HttpError(429, gemini_quota),
    )
  let assert Some(gemini_msg) =
    antigravity.explain(home, "", first, types.HttpError(429, gemini_quota))
  string.contains(
    gemini_msg,
    "Antigravity Gemini quota exhausted for one@example.com",
  )
  |> should.be_true
  string.contains(gemini_msg, "its gemini meter") |> should.be_true
  string.contains(
    gemini_msg,
    "no other Google account has room on the Gemini meter.",
  )
  |> should.be_true
  string.contains(gemini_msg, "two@example.com is limited on Claude until")
  |> should.be_true

  cleanup(root)
}

pub fn antigravity_claude_declares_anthropic_image_limits_test() -> Nil {
  let #(root, _, home) = fixture()
  let _ = write(home, "creds.json", google_accounts)
  let assert [harness_extension.ModelProviderPlugin(provider)] =
    list.filter(antigravity.extension().plugins, fn(plugin) {
      case plugin {
        harness_extension.ModelProviderPlugin(_) -> True
        _ -> False
      }
    })
  let images = fn(model) {
    let assert Some(Ok(upstream)) =
      provider.resolve(harness_extension.ModelContext(
        home,
        "image-session",
        "",
        "antigravity",
        model,
        types.ChatCompletions,
        None,
      ))
    upstream.images
  }
  images("claude-sonnet-4-6") |> should.equal(types.anthropic_images)
  images("gemini-3-flash") |> should.equal(types.any_images)
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
    rotation.Budget(8, 0, no_wait, False),
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
    rotation.Budget(
      8,
      0,
      fn(delay) { process.send(paused, int.to_string(delay)) },
      False,
    ),
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
    rotation.Budget(8, 0, no_wait, False),
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

fn opencode_go_config(a: String, b: String) -> String {
  "{\"providers\":{\"go-a\":{\"extension\":\"opencode-go\",\"baseUrl\":\"http://127.0.0.1:1/a\",\"apiKey\":\""
  <> a
  <> "\",\"protocol\":\"chat_completions\"},\"go-b\":{\"extension\":\"opencode-go\",\"baseUrl\":\"http://127.0.0.1:1/b\",\"apiKey\":\""
  <> b
  <> "\",\"protocol\":\"chat_completions\"},\"other\":{\"extension\":\"openai\",\"baseUrl\":\"http://x\",\"apiKey\":\"not-go\"}}}"
}

pub fn opencode_go_rotates_and_sends_session_header_test() -> Nil {
  let #(root, _, home) = fixture()
  let first_key = "go-a-" <> int.to_string(unique())
  let second_key = "go-b-" <> int.to_string(unique())
  let _ = write(home, "config.json", opencode_go_config(first_key, second_key))
  let tried = process.new_subject()
  let body =
    "{\"error\":{\"type\":\"UsageLimit\",\"message\":\"Rolling 5h usage limit reached\"}}"
  let pool = opencode_go.pool(home, "go-a", "go-session")
  let assert Ok(first) = pool.current()
  first.api_key |> should.equal(first_key)
  first.base_url |> should.equal("http://127.0.0.1:1/a")
  first.policy |> should.equal(types.OpenCodeGo("go-session", ""))
  openai_api.headers(first, "glm-5.3-flash")
  |> list.contains(#("x-opencode-session", "go-session"))
  |> should.be_true
  rotation.stream(
    rotation.Pool(
      ..pool,
      stream: limited_stream([first_key], body, tried, api_key),
    ),
    first,
    openai_api.request("glm-5.3-flash", [types.User("hi")]),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, no_wait, False),
    fn(_) { Nil },
  )
  |> should.equal(Error(types.HttpError(500, "sibling answered")))
  drain(tried, []) |> should.equal([first_key, second_key])
  let assert Ok(next) = pool.current()
  next.api_key |> should.equal(second_key)
  next.base_url |> should.equal("http://127.0.0.1:1/b")
  cleanup(root)
}

pub fn opencode_go_oauth_account_sends_org_header_test() -> Nil {
  let #(root, _, home) = fixture()
  let token = "oauth-go-" <> int.to_string(unique())
  let _ =
    write(
      home,
      "config.json",
      "{\"providers\":{\"go\":{\"extension\":\"opencode-go\",\"protocol\":\"chat_completions\",\"model\":\"glm-5.3-flash\"}}}",
    )
  let _ =
    write(
      home,
      "creds.json",
      "{\"accounts\":{\"opencode-go\":[{\"type\":\"oauth\",\"access\":\""
        <> token
        <> "\",\"refresh\":\"ref-1\",\"expires\":9999999999999,\"accountId\":\"usr_1\",\"email\":\"dawn@example.com\",\"orgId\":\"org_42\",\"orgName\":\"Personal\"}]}}",
    )
  let pool = opencode_go.pool(home, "go", "go-oauth-session")
  let assert Ok(client) = pool.current()
  client.api_key |> should.equal(token)
  client.policy |> should.equal(types.OpenCodeGo("go-oauth-session", "org_42"))
  let sent_headers = openai_api.headers(client, "glm-5.3-flash")
  sent_headers
  |> list.contains(#("x-opencode-session", "go-oauth-session"))
  |> should.be_true
  sent_headers
  |> list.contains(#("x-opencode-org-id", "org_42"))
  |> should.be_true
  let assert [account] = oauth.accounts(home, opencode_go.login())
  account.label |> should.equal("dawn@example.com · Personal")
  cleanup(root)
}

pub fn opencode_go_dispatches_each_model_family_to_its_wire_route_test() -> Nil {
  opencode_go_wire.route("glm-5.3-flash")
  |> should.equal(opencode_go_wire.ChatRoute)
  opencode_go_wire.route("qwen3.8-max")
  |> should.equal(opencode_go_wire.ChatRoute)
  opencode_go_wire.route("gpt-5.6-luna")
  |> should.equal(opencode_go_wire.ResponsesRoute)
  opencode_go_wire.route("grok-4.7")
  |> should.equal(opencode_go_wire.ResponsesRoute)
  opencode_go_wire.route("muse-spark-1.2-contributor")
  |> should.equal(opencode_go_wire.ResponsesRoute)
  opencode_go_wire.route("claude-haiku-5-5")
  |> should.equal(opencode_go_wire.MessagesRoute)
  opencode_go_wire.route("minimax-m2.7")
  |> should.equal(opencode_go_wire.MessagesRoute)
  opencode_go_wire.route("gemini-4-argon-contributor")
  |> should.equal(opencode_go_wire.GeminiRoute)

  let client =
    openai_api.opencode_go_client(
      "https://opencode.ai/zen/go/v1",
      "test-token",
      "sess-1",
      "org-1",
    )
  let req =
    types.Request(
      "gemini-4-argon-contributor",
      Some("be brief"),
      [types.User("hi")],
      [],
      Some(256),
      types.Options(..types.defaults, effort: Some("low")),
    )
  let assert Ok(gem_ex) = opencode_go_wire.encode_gemini(client, req)
  gem_ex.url
  |> should.equal(
    "https://opencode.ai/inference/go/v1/models/gemini-4-argon-contributor:streamGenerateContent?alt=sse",
  )
  gem_ex.headers
  |> list.contains(#("x-opencode-org-id", "org-1"))
  |> should.be_true

  let reducer = vertex_stream.reducer()
  let assert Ok(#(reducer, _, None)) =
    reducer.feed(
      "{\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"pong\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":4,\"candidatesTokenCount\":1}}",
    )
  let assert Ok(turn) = reducer.finish()
  let assert [replay_item] = turn.output
  types.replay_protocol(replay_item) |> should.equal(types.ChatCompletions)

  // Replay that portable item into a Responses-routed model and a Messages-routed model.
  let follow_up =
    types.Request(
      "gpt-5.6-luna",
      None,
      [types.User("hi"), types.Replay(replay_item), types.User("again")],
      [],
      Some(128),
      types.defaults,
    )
  let assert Ok(resp_ex) = opencode_go_wire.encode_responses(client, follow_up)
  resp_ex.url
  |> should.equal("https://opencode.ai/inference/go/v1/responses")

  let msg_req = types.Request(..follow_up, model: "claude-haiku-5-5")
  let assert Ok(msg_ex) = opencode_go_wire.encode_messages(client, msg_req)
  msg_ex.url
  |> should.equal("https://opencode.ai/inference/go/v1/messages")
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

pub fn account_order_keeps_selected_limited_and_tied_deadlines_distinct_test() -> Nil {
  let entries = [
    accounts.Entry("limited-selected", "a", True, 300),
    accounts.Entry("open", "b", False, 0),
    accounts.Entry("selected", "c", True, 0),
    accounts.Entry("limited-first", "d", False, 200),
    accounts.Entry("limited-second", "e", False, 200),
  ]
  accounts.order(entries, "session", Some("b"), 100)
  |> should.equal([
    "selected",
    "open",
    "limited-first",
    "limited-second",
    "limited-selected",
  ])
  accounts.order(entries, "session", Some("a"), 100)
  |> should.equal([
    "selected",
    "open",
    "limited-first",
    "limited-second",
    "limited-selected",
  ])
  accounts.order([], "session", None, 100) |> should.equal([])
}

pub fn account_spreading_preserves_fnv1a_byte_hash_test() -> Nil {
  let entries =
    list.map([0, 1, 2, 3, 4, 5, 6], fn(value) {
      accounts.Entry(value, int.to_string(value), False, 0)
    })
  // FNV-1a over these bytes is 0x4F9F2CAB, including 32-bit overflow.
  accounts.order(entries, "hello", None, 0)
  |> should.equal([2, 3, 4, 5, 6, 0, 1])
}

@external(erlang, "albedo_accounts", "order")
fn native_order(
  scope: String,
  values: List(Dict(String, Dynamic)),
  session: String,
  identity: fn(Dict(String, Dynamic)) -> String,
) -> List(Dict(String, Dynamic))

@external(erlang, "albedo_accounts", "remember")
fn remember(scope: String, session: String, identity: String) -> Dynamic

pub fn native_order_only_reads_identity_for_usable_sticky_accounts_test() -> Nil {
  let account = dict.from_list([#("access", dynamic.string("unread token"))])
  let no_identity = fn(_) {
    panic as "this order does not need account identity"
  }
  native_order("identity-contract", [account], "unpinned", no_identity)
  |> should.equal([account])
  let _ = remember("identity-contract", "pinned", "chosen")
  let limited =
    dict.insert(
      account,
      "limitedUntil",
      dynamic.int(clock.system_ms() + 1_000_000),
    )
  native_order("identity-contract", [limited], "pinned", no_identity)
  |> should.equal([limited])
}

/// A pool over two tokens where a rejection makes `current` sign in afresh,
/// recording every attempt.
fn renewing_pool(
  tried: process.Subject(String),
  answer: fn(String) -> Result(types.Turn, types.Error),
  renews: Bool,
) -> rotation.Pool(String) {
  let rejected = process.new_subject()
  rotation.Pool(
    current: fn() {
      case process.receive(rejected, 0), renews {
        Ok(_), True -> Ok("fresh")
        _, _ -> Ok("stale")
      }
    },
    mark: fn(_, _) { None },
    same: fn(a, b) { a == b },
    stream: fn(account, _, _) {
      process.send(tried, account)
      answer(account)
    },
    reject: fn(account) { process.send(rejected, account) },
  )
}

fn renew(pool: rotation.Pool(String)) -> Result(types.Turn, types.Error) {
  rotation.stream(
    pool,
    "stale",
    request(),
    fn(_) { types.Continue },
    rotation.Budget(8, 0, no_wait, False),
    fn(_) { Nil },
  )
}

pub fn a_refused_credential_is_renewed_and_retried_once_test() -> Nil {
  let tried = process.new_subject()
  let answer = fn(account) {
    case account {
      "stale" -> Error(types.HttpError(401, "expired"))
      _ -> Error(types.HttpError(500, "fresh answered"))
    }
  }
  renewing_pool(tried, answer, True)
  |> renew
  |> should.equal(Error(types.HttpError(500, "fresh answered")))
  drain(tried, []) |> should.equal(["stale", "fresh"])
}

pub fn a_credential_that_cannot_be_renewed_fails_at_once_test() -> Nil {
  let tried = process.new_subject()
  renewing_pool(tried, fn(_) { Error(types.HttpError(401, "bad key")) }, False)
  |> renew
  |> should.equal(Error(types.HttpError(401, "bad key")))
  drain(tried, []) |> should.equal(["stale"])
}

pub fn a_renewed_credential_refused_again_is_not_retried_test() -> Nil {
  let tried = process.new_subject()
  renewing_pool(tried, fn(_) { Error(types.HttpError(401, "revoked")) }, True)
  |> renew
  |> should.equal(Error(types.HttpError(401, "revoked")))
  drain(tried, []) |> should.equal(["stale", "fresh"])
}
