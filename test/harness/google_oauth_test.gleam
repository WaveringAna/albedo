// A refresh moves a stored token, so it is checked against a local token endpoint rather than a scripted model turn.
import gleam/string
import gleeunit/should

const stale =
  "{\"type\":\"oauth\",\"access\":\"old\",\"refresh\":\"r1\",\"expires\":0,\"email\":\"a@example.com\"}"

const other =
  "{\"type\":\"oauth\",\"access\":\"keep\",\"refresh\":\"r2\",\"expires\":0,\"email\":\"b@example.com\"}"

const fresh = "99999999999999"

fn accounts(items: List(String)) -> String {
  "[" <> string.join(items, ",") <> "]"
}

pub fn a_stale_account_is_refreshed_saved_and_the_others_left_alone_test() -> Nil {
  let #(result, stored, form) =
    refresh(accounts([stale, other]), #(
      200,
      "{\"access_token\":\"new\",\"expires_in\":3600}",
    ))
  result |> should.equal(Ok("new"))
  string.contains(stored, "\"access\":\"new\"") |> should.be_true
  string.contains(stored, "\"refresh\":\"r1\"") |> should.be_true
  string.contains(stored, "\"access\":\"keep\"") |> should.be_true
  string.contains(form, "grant_type=refresh_token") |> should.be_true
  string.contains(form, "refresh_token=r1") |> should.be_true
}

pub fn a_rotated_refresh_token_replaces_the_old_one_test() -> Nil {
  let #(_, stored, _) =
    refresh(accounts([stale]), #(
      200,
      "{\"access_token\":\"new\",\"refresh_token\":\"r9\",\"expires_in\":3600}",
    ))
  string.contains(stored, "\"refresh\":\"r9\"") |> should.be_true
  string.contains(stored, "r1") |> should.be_false
}

pub fn a_rejected_refresh_keeps_the_stored_account_test() -> Nil {
  let #(result, stored, _) =
    refresh(accounts([stale]), #(400, "{\"error\":\"invalid_grant\"}"))
  result |> should.equal(Error("Google Colab token refresh failed (400)"))
  string.contains(stored, "\"access\":\"old\"") |> should.be_true
}

pub fn an_account_without_a_refresh_token_is_invalid_test() -> Nil {
  let #(result, _, _) =
    refresh(
      accounts(["{\"type\":\"oauth\",\"access\":\"old\",\"expires\":0}"]),
      #(200, "{}"),
    )
  result |> should.equal(Error("invalid"))
}

pub fn colab_uses_the_selected_account_and_names_its_email_test() -> Nil {
  let selected =
    "{\"type\":\"oauth\",\"access\":\"second\",\"refresh\":\"r2\",\"expires\":"
    <> fresh
    <> ",\"email\":\"b@example.com\",\"selected\":true}"
  let first =
    "{\"type\":\"oauth\",\"access\":\"first\",\"refresh\":\"r1\",\"expires\":"
    <> fresh
    <> ",\"email\":\"a@example.com\"}"
  signed_in(accounts([first, selected]))
  |> should.equal(Ok(#("second", "b@example.com")))
  signed_in(accounts([first, first]))
  |> should.equal(Ok(#("first", "a@example.com")))
}

pub fn colab_with_no_account_says_to_sign_in_test() -> Nil {
  signed_in("[]")
  |> should.equal(Error(
    "Google Colab is not authenticated; run /login and add a Google Colab account",
  ))
}

@external(erlang, "albedo_google_oauth_test_support", "refresh")
fn refresh(
  accounts: String,
  answer: #(Int, String),
) -> #(Result(String, String), String, String)

@external(erlang, "albedo_google_oauth_test_support", "signed_in")
fn signed_in(accounts: String) -> Result(#(String, String), String)
