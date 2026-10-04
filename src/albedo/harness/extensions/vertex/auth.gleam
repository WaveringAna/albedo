//// Google Application Default Credentials for Vertex AI: a service-account
//// key (signs its own JWT) or a refresh-token credential (a user or
//// workforce-federated login). No browser flow: both are already
//// authorized before albedo runs.

import albedo/clock
import gleam/bit_array
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

pub type Credentials {
  ServiceAccount(client_email: String, private_key: String, token_uri: String)
  RefreshToken(
    client_id: String,
    client_secret: String,
    refresh_token: String,
    token_uri: String,
    // STS's token-exchange endpoint (the workforce-federated shape) takes
    // client credentials as HTTP Basic, not body fields; Google's own
    // oauth2.googleapis.com token endpoint takes the body fields.
    basic_auth: Bool,
  )
}

const default_token_uri = "https://oauth2.googleapis.com/token"

const cloud_platform_scope = "https://www.googleapis.com/auth/cloud-platform"

type Raw {
  Raw(
    private_key: String,
    client_email: String,
    client_id: String,
    client_secret: String,
    refresh_token: String,
    token_uri: String,
    token_url: String,
  )
}

pub fn load(path: String) -> Result(Credentials, String) {
  use text <- result.try(
    read_file(path)
    |> result.replace_error("could not read Vertex credentials at " <> path),
  )
  from_text(text)
}

/// The pure half of `load`: a credential JSON document, without touching
/// disk. Branches on which fields are present, not on a literal `type`, so
/// both `authorized_user` and Workforce Federation's
/// `external_account_authorized_user` resolve the same way.
pub fn from_text(text: String) -> Result(Credentials, String) {
  use raw <- result.try(
    json.parse(text, raw_decoder())
    |> result.replace_error("invalid Vertex credentials JSON"),
  )
  let token_uri =
    non_empty(raw.token_uri)
    |> option.or(non_empty(raw.token_url))
    |> option.unwrap(default_token_uri)
  case raw.private_key, raw.client_email {
    "", _ | _, "" ->
      case raw.refresh_token, raw.client_id, raw.client_secret {
        "", _, _ | _, "", _ | _, _, "" ->
          Error(
            "Vertex credentials are neither a service-account key nor a refresh-token credential",
          )
        refresh_token, client_id, client_secret ->
          Ok(RefreshToken(
            client_id,
            client_secret,
            refresh_token,
            token_uri,
            basic_auth: raw.token_url != "",
          ))
      }
    private_key, client_email ->
      Ok(ServiceAccount(client_email, private_key, token_uri))
  }
}

fn non_empty(value: String) -> Option(String) {
  case value {
    "" -> None
    _ -> Some(value)
  }
}

fn raw_decoder() -> decode.Decoder(Raw) {
  use private_key <- decode.optional_field("private_key", "", decode.string)
  use client_email <- decode.optional_field("client_email", "", decode.string)
  use client_id <- decode.optional_field("client_id", "", decode.string)
  use client_secret <- decode.optional_field("client_secret", "", decode.string)
  use refresh_token <- decode.optional_field("refresh_token", "", decode.string)
  use token_uri <- decode.optional_field("token_uri", "", decode.string)
  use token_url <- decode.optional_field("token_url", "", decode.string)
  decode.success(Raw(
    private_key,
    client_email,
    client_id,
    client_secret,
    refresh_token,
    token_uri,
    token_url,
  ))
}

/// A fresh access token. There is no cache: a Vertex call costs one extra
/// HTTP round trip for this, same tradeoff as every short-lived credential
/// albedo does not hold a refresh loop for.
pub fn access_token(creds: Credentials) -> Result(String, String) {
  case creds {
    ServiceAccount(client_email, private_key, token_uri) ->
      service_account_token(client_email, private_key, token_uri)
    RefreshToken(client_id, client_secret, refresh_token, token_uri, basic_auth) ->
      case basic_auth {
        True ->
          post_for_token_as(
            token_uri,
            form([
              #("grant_type", "refresh_token"),
              #("refresh_token", refresh_token),
            ]),
            Some(basic_header(client_id, client_secret)),
          )
        False ->
          post_for_token_as(
            token_uri,
            form([
              #("grant_type", "refresh_token"),
              #("client_id", client_id),
              #("client_secret", client_secret),
              #("refresh_token", refresh_token),
            ]),
            None,
          )
      }
  }
}

fn service_account_token(
  client_email: String,
  private_key: String,
  token_uri: String,
) -> Result(String, String) {
  let now = clock.system_seconds()
  let header =
    json.object([#("alg", json.string("RS256")), #("typ", json.string("JWT"))])
  let claims =
    json.object([
      #("iss", json.string(client_email)),
      #("scope", json.string(cloud_platform_scope)),
      #("aud", json.string(token_uri)),
      #("iat", json.int(now)),
      #("exp", json.int(now + 3600)),
    ])
  let signing_input = b64(header) <> "." <> b64(claims)
  use signature <- result.try(sign(
    bit_array.from_string(private_key),
    bit_array.from_string(signing_input),
  ))
  let assertion =
    signing_input <> "." <> bit_array.base64_url_encode(signature, False)
  post_for_token_as(
    token_uri,
    form([
      #("grant_type", "urn:ietf:params:oauth:grant-type:jwt-bearer"),
      #("assertion", assertion),
    ]),
    None,
  )
}

fn basic_header(client_id: String, client_secret: String) -> String {
  "Basic "
  <> bit_array.base64_encode(
    bit_array.from_string(client_id <> ":" <> client_secret),
    True,
  )
}

fn b64(value: json.Json) -> String {
  bit_array.base64_url_encode(
    bit_array.from_string(json.to_string(value)),
    False,
  )
}

fn form(pairs: List(#(String, String))) -> String {
  pairs
  |> list.map(fn(pair) {
    uri.percent_encode(pair.0) <> "=" <> uri.percent_encode(pair.1)
  })
  |> string.join("&")
}

fn post_for_token_as(
  token_uri: String,
  body: String,
  authorization: Option(String),
) -> Result(String, String) {
  let headers = case authorization {
    Some(value) -> [
      #("content-type", "application/x-www-form-urlencoded"),
      #("authorization", value),
    ]
    None -> [#("content-type", "application/x-www-form-urlencoded")]
  }
  let #(status, response) = http_request("POST", token_uri, headers, Some(body))
  case status {
    200 ->
      json.parse(
        response,
        decode.field("access_token", decode.string, decode.success),
      )
      |> result.replace_error("Vertex token response had no access_token")
    _ ->
      Error(
        "Vertex token request failed ("
        <> int.to_string(status)
        <> "): "
        <> response,
      )
  }
}

fn read_file(path: String) -> Result(String, Nil) {
  use bytes <- result.try(read_file_raw(path) |> result.replace_error(Nil))
  bit_array.to_string(bytes) |> result.replace_error(Nil)
}

@external(erlang, "file", "read_file")
fn read_file_raw(path: String) -> Result(BitArray, Dynamic)

@external(erlang, "albedo_usage_core", "http_request")
fn http_request(
  method: String,
  url: String,
  headers: List(#(String, String)),
  body: Option(String),
) -> #(Int, String)

@external(erlang, "albedo_vertex", "rs256_sign")
fn sign(
  private_key_pem: BitArray,
  message: BitArray,
) -> Result(BitArray, String)
