// OAuth callback races, state validation, and fixed-port contention are timing-sensitive and cannot be scripted as an E2E model turn.
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

pub fn a_pasted_redirect_races_the_callback_test() -> Nil {
  let #(root, _, home) = fixture()
  let assert Ok(#(id, url)) = oauth.start(home, ephemeral())
  let assert Ok(state) = list.key_find(query(url), "state")
  let assert Ok(Nil) =
    oauth.input(id, "http://127.0.0.1:9/cb?code=cy&state=" <> state)
  assert settle(id, 100) == oauth.Done("cy@example.com")
  cleanup(root)
}

pub fn a_pasted_code_for_another_attempt_is_rejected_test() -> Nil {
  let #(root, _, home) = fixture()
  let assert Ok(#(id, _)) = oauth.start(home, ephemeral())
  let assert Ok(Nil) = oauth.input(id, "cy#not-this-state")
  assert settle(id, 100) == oauth.Failed("oauth state mismatch")
  cleanup(root)
}

pub fn a_busy_fixed_port_fails_instead_of_moving_test() -> Nil {
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

@external(erlang, "erlang", "integer_to_binary")
fn int_to_string(value: Int) -> String

@external(erlang, "albedo_oauth_test_support", "occupy")
fn occupy(port: Int) -> #(dynamic.Dynamic, Int)

@external(erlang, "albedo_oauth_test_support", "release")
fn release(taken: #(dynamic.Dynamic, Int)) -> Nil

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil
