// OAuth callback races, state validation, and fixed-port contention are timing-sensitive and cannot be scripted as an E2E model turn.
import albedo/daemon/http_api
import albedo/harness/oauth
import albedo/openai_api/types
import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{Some}
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

fn start(home: String, login: oauth.Login) -> #(String, String) {
  let id = identity()
  let assert Ok(#(True, flow)) =
    oauth.start_identified(
      home,
      id,
      "fake",
      Some(login),
      "{\"provider\":\"fake\"}",
    )
  #(id, flow)
}

fn field(flow: String, key: String) -> String {
  let assert Ok(value) =
    json.parse(flow, decode.field(key, decode.string, decode.success))
  value
}

fn settle(
  home: String,
  id: String,
  login: oauth.Login,
  attempts: Int,
) -> String {
  let assert Ok(flow) = oauth.get_identified(home, id, [login])
  case field(flow, "state"), attempts {
    "waiting", n | "exchanging", n if n > 0 -> {
      process.sleep(20)
      settle(home, id, login, n - 1)
    }
    _, _ -> flow
  }
}

pub fn a_pasted_redirect_races_the_callback_test() -> Nil {
  let #(root, _, home) = fixture()
  let login = ephemeral()
  let #(id, flow) = start(home, login)
  let assert Ok(state) = list.key_find(query(field(flow, "url")), "state")
  let assert Ok(_) =
    oauth.input_identified(
      home,
      id,
      http_api.etag(flow),
      "http://127.0.0.1:9/cb?code=cy&state=" <> state,
      [login],
    )
  let complete = settle(home, id, login, 100)
  assert field(complete, "state") == "complete"
  let assert [account] = oauth.accounts(home, login)
  assert account.label == "cy@example.com"
  // Terminal outcome remains durable after the flow process has stopped.
  let assert Ok(retained) = oauth.get_identified(home, id, [login])
  assert retained == complete
  cleanup(root)
}

pub fn a_pasted_code_for_another_attempt_is_rejected_test() -> Nil {
  let #(root, _, home) = fixture()
  let login = ephemeral()
  let #(id, flow) = start(home, login)
  let assert Ok(_) =
    oauth.input_identified(home, id, http_api.etag(flow), "cy#not-this-state", [
      login,
    ])
  let failed = settle(home, id, login, 100)
  assert field(failed, "state") == "failed"
  assert field(failed, "failure") == "Provider authorization failed."
  assert oauth.accounts(home, login) == []
  cleanup(root)
}

pub fn a_busy_fixed_port_fails_instead_of_moving_test() -> Nil {
  let taken = occupy(0)
  let port = taken.1
  let #(root, _, home) = fixture()
  let fixed = fake(oauth.Callback("127.0.0.1", port, "/cb", True))
  let #(_, failed) = start(home, fixed)
  assert field(failed, "state") == "failed"
  assert string.contains(field(failed, "failure"), "callback listener")
  let login = fake(oauth.Callback("127.0.0.1", port, "/cb", False))
  let #(id, flow) = start(home, login)
  let assert Ok(redirect) =
    list.key_find(query(field(flow, "url")), "redirect_uri")
  assert !string.contains(redirect, ":" <> int_to_string(port) <> "/")
  let assert Ok(cancelled) = oauth.cancel_identified(home, id, [login])
  assert field(cancelled, "state") == "cancelled"
  release(taken)
  cleanup(root)
}

@external(erlang, "albedo_oauth_test_support", "identity")
fn identity() -> String

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
