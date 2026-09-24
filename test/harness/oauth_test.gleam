import albedo/harness/extensions/codex/extension as codex
import albedo/harness/oauth
import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri

fn fake(callback: oauth.Callback) -> oauth.Login {
  oauth.Login(
    "fake",
    "add fake account",
    "",
    types.ChatCompletions,
    "fake-accounts",
    callback,
    fn(grant) {
      "https://auth.example/authorize?"
      <> uri.query_to_string([
        #("redirect_uri", grant.redirect),
        #("state", grant.state),
      ])
    },
    fn(_grant, code, progress) {
      progress("provisioning " <> code)
      case code {
        "bad" -> Error("exchange rejected")
        _ ->
          Ok(
            json.object([
              #("type", json.string("oauth")),
              #("access", json.string("access-" <> code)),
              #("email", json.string(code <> "@example.com")),
            ]),
          )
      }
    },
    fn(credential) {
      let email =
        decode.run(credential, decode.at(["email"], decode.string))
        |> result.unwrap("")
      let selected =
        decode.run(credential, decode.at(["selected"], decode.bool))
        |> result.unwrap(False)
      oauth.Account(email, email, "fake account", selected)
    },
  )
}

fn ephemeral() -> oauth.Login {
  fake(oauth.Callback("127.0.0.1", 0, "/cb", False))
}

fn query(url: String) -> List(#(String, String)) {
  let assert Ok(parsed) = uri.parse(url)
  let assert Ok(pairs) = uri.parse_query(option.unwrap(parsed.query, ""))
  pairs
}

fn settle(id: String, attempts: Int) -> oauth.Status {
  let assert Ok(status) = oauth.status(id)
  case status, attempts {
    oauth.Waiting(_), n | oauth.Exchanging(_), n if n > 0 -> {
      process.sleep(20)
      settle(id, n - 1)
    }
    status, _ -> status
  }
}

fn callback(url: String, extra: List(#(String, String))) -> Int {
  let pairs = query(url)
  let assert Ok(redirect) = list.key_find(pairs, "redirect_uri")
  let assert Ok(state) = list.key_find(pairs, "state")
  http_get(
    redirect
    <> "?"
    <> uri.query_to_string(list.append(extra, [#("state", state)])),
  )
}

pub fn browser_callback_stores_and_replaces_the_account_test() {
  let #(root, _, home) = fixture()
  let login = ephemeral()
  let assert Ok(#(id, url)) = oauth.start(home, login)
  assert string.starts_with(url, "https://auth.example/authorize?")
  assert callback(url, [#("code", "amy")]) == 200
  assert settle(id, 100) == oauth.Done("amy@example.com")
  // The same identity signs in again: replaced, not duplicated.
  let assert Ok(#(again, url)) = oauth.start(home, login)
  assert callback(url, [#("code", "amy")]) == 200
  assert settle(again, 100) == oauth.Done("amy@example.com")
  let assert [_] = oauth.accounts(home, login)
  cleanup(root)
}

pub fn accounts_can_be_selected_and_removed_test() {
  let #(root, _, home) = fixture()
  let login = ephemeral()
  list.each(["amy", "bo"], fn(code) {
    let assert Ok(#(id, url)) = oauth.start(home, login)
    assert callback(url, [#("code", code)]) == 200
    assert settle(id, 100) == oauth.Done(code <> "@example.com")
  })
  let assert Ok(Nil) = oauth.select(home, login, "bo@example.com")
  assert list.map(oauth.accounts(home, login), fn(a) { #(a.id, a.selected) })
    == [#("amy@example.com", False), #("bo@example.com", True)]
  let assert Ok(Nil) = oauth.remove(home, login, "amy@example.com")
  assert list.map(oauth.accounts(home, login), fn(a) { a.id })
    == ["bo@example.com"]
  cleanup(root)
}

pub fn a_pasted_redirect_races_the_callback_test() {
  let #(root, _, home) = fixture()
  let assert Ok(#(id, url)) = oauth.start(home, ephemeral())
  let assert Ok(state) = list.key_find(query(url), "state")
  let assert Ok(Nil) =
    oauth.input(id, "http://127.0.0.1:9/cb?code=cy&state=" <> state)
  assert settle(id, 100) == oauth.Done("cy@example.com")
  cleanup(root)
}

pub fn a_pasted_code_for_another_attempt_is_rejected_test() {
  let #(root, _, home) = fixture()
  let assert Ok(#(id, _)) = oauth.start(home, ephemeral())
  let assert Ok(Nil) = oauth.input(id, "cy#not-this-state")
  assert settle(id, 100) == oauth.Failed("oauth state mismatch")
  cleanup(root)
}

pub fn denied_consent_and_failed_exchange_fail_the_sign_in_test() {
  let #(root, _, home) = fixture()
  let login = ephemeral()
  let assert Ok(#(denied, url)) = oauth.start(home, login)
  let _ = callback(url, [#("error", "access_denied")])
  let assert oauth.Failed(reason) = settle(denied, 100)
  assert string.contains(reason, "access_denied")
  let assert Ok(#(rejected, url)) = oauth.start(home, login)
  let _ = callback(url, [#("code", "bad")])
  assert settle(rejected, 100) == oauth.Failed("exchange rejected")
  assert oauth.accounts(home, login) == []
  cleanup(root)
}

pub fn a_busy_fixed_port_fails_instead_of_moving_test() {
  let taken = occupy(0)
  let port = taken.1
  let #(root, _, home) = fixture()
  let assert Error(reason) =
    oauth.start(home, fake(oauth.Callback("127.0.0.1", port, "/cb", True)))
  assert string.contains(reason, "could not listen")
  // Without a fixed port the sign-in moves to an ephemeral one.
  let assert Ok(#(id, url)) =
    oauth.start(home, fake(oauth.Callback("127.0.0.1", port, "/cb", False)))
  let assert Ok(redirect) = list.key_find(query(url), "redirect_uri")
  assert !string.contains(redirect, ":" <> int_to_string(port) <> "/")
  let assert Ok(Nil) = oauth.cancel(id)
  let assert Error(_) = oauth.status(id)
  release(taken)
  cleanup(root)
}

pub fn codex_authorizes_with_pkce_on_its_allowlisted_redirect_test() {
  let login = codex.login()
  let url =
    login.authorize(oauth.Grant(
      "http://localhost:1455/auth/callback",
      "s1",
      "v",
      "c1",
    ))
  let pairs = query(url)
  assert list.key_find(pairs, "redirect_uri")
    == Ok("http://localhost:1455/auth/callback")
  assert list.key_find(pairs, "code_challenge") == Ok("c1")
  assert list.key_find(pairs, "code_challenge_method") == Ok("S256")
  assert login.callback
    == oauth.Callback("localhost", 1455, "/auth/callback", True)
  let assert Ok(stored) =
    json.parse(
      "{\"type\":\"oauth\",\"access\":\"a\",\"refresh\":\"r\",\"expires\":1,\"accountId\":\"acct-1\",\"email\":\"me@example.com\",\"selected\":true}",
      decode.dynamic,
    )
  let account = login.account(stored)
  assert account.label == "me@example.com"
  assert account.detail == "chatgpt account · selected"
  assert account.selected
}

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(value: Int) -> String

@external(erlang, "albedo_oauth_test_support", "get")
fn http_get(url: String) -> Int

@external(erlang, "albedo_oauth_test_support", "occupy")
fn occupy(port: Int) -> #(dynamic.Dynamic, Int)

@external(erlang, "albedo_oauth_test_support", "release")
fn release(taken: #(dynamic.Dynamic, Int)) -> Nil

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
