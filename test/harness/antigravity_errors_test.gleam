//// Verification errors need escaped and malformed provider envelopes that a
//// model-turn E2E fixture cannot inject into the authenticated discovery flow.

import albedo/harness/extensions/antigravity/errors
import gleam/json
import gleam/string
import gleeunit/should

fn body(details: List(json.Json)) -> String {
  json.object([
    #("error", json.object([#("details", json.array(details, fn(x) { x }))])),
  ])
  |> json.to_string
}

fn required(url: json.Json) -> json.Json {
  json.object([
    #("reason", json.string("VALIDATION_REQUIRED")),
    #("metadata", json.object([#("validation_url", url)])),
  ])
}

pub fn escaped_verification_url_is_decoded_before_display_test() -> Nil {
  let response =
    "{\"error\":{\"details\":[{\"reason\":\"VALIDATION_REQUIRED\",\"metadata\":{\"validation_url\":\"https:\\/\\/example.com\\/verify?q=\\\"yes\\\"\"}}]}}"
  errors.verification_url(response)
  |> should.equal(Ok("https://example.com/verify?q=\"yes\""))
  discover(response)
  |> should.equal(Error(
    "Account verification required. Visit https://example.com/verify?q=\"yes\" to continue, then sign in again.",
  ))
}

pub fn verification_links_beyond_display_limit_survive_test() -> Nil {
  let response =
    body([
      json.object([#("reason", json.string(string.repeat("x", 3000)))]),
      required(json.string("https://example.com/verify")),
    ])
  discover(response)
  |> should.equal(Error(
    "Account verification required. Visit https://example.com/verify to continue, then sign in again.",
  ))
}

pub fn missing_empty_or_invalid_links_use_account_fallback_test() -> Nil {
  let responses = [
    body([json.object([#("reason", json.string("VALIDATION_REQUIRED"))])]),
    body([required(json.string(""))]),
    body([required(json.int(12))]),
  ]
  let assert [a, b, c] = responses
  for_fallback(a)
  for_fallback(b)
  for_fallback(c)
}

fn for_fallback(response: String) -> Nil {
  errors.verification_url(response) |> should.equal(Ok(""))
  discover(response)
  |> should.equal(Error(
    "Account verification required. Visit https://accounts.google.com to continue, then sign in again.",
  ))
}

pub fn later_usable_link_wins_over_missing_metadata_test() -> Nil {
  errors.verification_url(
    body([
      json.int(1),
      required(json.null()),
      required(json.string("https://example.com/verify")),
    ]),
  )
  |> should.equal(Ok("https://example.com/verify"))
}

pub fn malformed_and_unrelated_errors_keep_failure_format_test() -> Nil {
  let malformed = "invalid VALIDATION_REQUIRED"
  let unrelated = body([json.object([#("reason", json.string("OTHER"))])])
  errors.verification_url(malformed) |> should.equal(Error(Nil))
  errors.verification_url(unrelated) |> should.equal(Error(Nil))
  discover(malformed)
  |> should.equal(Error(
    "/v1internal:loadCodeAssist failed (403): " <> malformed,
  ))
  discover(unrelated)
  |> should.equal(Error(
    "/v1internal:loadCodeAssist failed (403): " <> unrelated,
  ))
}

@external(erlang, "albedo_antigravity_error_support", "discover")
fn discover(body: String) -> Result(String, String)
