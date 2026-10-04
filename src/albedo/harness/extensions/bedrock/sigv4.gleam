//// AWS SigV4 signing for Amazon Bedrock, from credentials a caller hands in
//// directly: no profile files, no SSO cache, no instance metadata.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type Credentials {
  Credentials(
    access_key_id: String,
    secret_access_key: String,
    session_token: Option(String),
  )
}

type Unit {
  Second
}

@external(erlang, "calendar", "system_time_to_universal_time")
fn universal_time(
  time: Int,
  unit: Unit,
) -> #(#(Int, Int, Int), #(Int, Int, Int))

fn amz_date(epoch_seconds: Int) -> #(String, String) {
  let #(#(y, mo, d), #(h, mi, s)) = universal_time(epoch_seconds, Second)
  let date = pad(y, 4) <> pad(mo, 2) <> pad(d, 2)
  #(date <> "T" <> pad(h, 2) <> pad(mi, 2) <> pad(s, 2) <> "Z", date)
}

fn pad(n: Int, width: Int) -> String {
  let text = int.to_string(n)
  case width - string.length(text) {
    missing if missing > 0 -> string.repeat("0", missing) <> text
    _ -> text
  }
}

fn hex(data: BitArray) -> String {
  bit_array.base16_encode(data) |> string.lowercase
}

fn hmac(key: BitArray, data: String) -> BitArray {
  crypto.hmac(bit_array.from_string(data), crypto.Sha256, key)
}

/// The signed headers, including `authorization`, for one POST of `body` to
/// `host` at `/anthropic/v1/messages` under `region`/`service`'s scope.
pub fn headers(
  creds: Credentials,
  region: String,
  service: String,
  host: String,
  now: Int,
  body: String,
) -> List(#(String, String)) {
  let #(amz_datetime, date_stamp) = amz_date(now)
  let payload_hash =
    hex(crypto.hash(crypto.Sha256, bit_array.from_string(body)))
  let signed =
    list.flatten([
      [
        #("content-type", "application/json"),
        #("host", host),
        #("x-amz-content-sha256", payload_hash),
        #("x-amz-date", amz_datetime),
      ],
      case creds.session_token {
        option.Some(token) -> [#("x-amz-security-token", token)]
        option.None -> []
      },
    ])
  let signed_headers = string.join(list.map(signed, fn(pair) { pair.0 }), ";")
  let canonical_headers =
    signed
    |> list.map(fn(pair) { pair.0 <> ":" <> pair.1 <> "\n" })
    |> string.concat
  let canonical_request =
    "POST\n/anthropic/v1/messages\n\n"
    <> canonical_headers
    <> "\n"
    <> signed_headers
    <> "\n"
    <> payload_hash
  let credential_scope =
    date_stamp <> "/" <> region <> "/" <> service <> "/aws4_request"
  let string_to_sign =
    "AWS4-HMAC-SHA256\n"
    <> amz_datetime
    <> "\n"
    <> credential_scope
    <> "\n"
    <> hex(crypto.hash(crypto.Sha256, bit_array.from_string(canonical_request)))
  let signing_key =
    bit_array.from_string("AWS4" <> creds.secret_access_key)
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(service)
    |> hmac("aws4_request")
  let signature = hex(hmac(signing_key, string_to_sign))
  let authorization =
    "AWS4-HMAC-SHA256 Credential="
    <> creds.access_key_id
    <> "/"
    <> credential_scope
    <> ", SignedHeaders="
    <> signed_headers
    <> ", Signature="
    <> signature
  list.append(signed, [#("authorization", authorization)])
}
