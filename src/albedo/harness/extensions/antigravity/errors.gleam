//// Structured Cloud Code Assist verification errors, before display truncation.

import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/result

/// An empty URL means verification is required but no usable link was supplied.
/// Other errors and malformed envelopes remain ordinary provider failures.
pub fn verification_url(body: String) -> Result(String, Nil) {
  use details <- result.try(
    json.parse(
      body,
      decode.at(["error", "details"], decode.list(decode.dynamic)),
    )
    |> result.replace_error(Nil),
  )
  let urls =
    list.filter_map(details, fn(detail) {
      case decode.run(detail, decode.at(["reason"], decode.string)) {
        Ok("VALIDATION_REQUIRED") ->
          Ok(
            decode.run(
              detail,
              decode.at(["metadata", "validation_url"], decode.string),
            )
            |> result.unwrap(""),
          )
        _ -> Error(Nil)
      }
    })
  case urls {
    [] -> Error(Nil)
    _ -> Ok(list.find(urls, fn(url) { url != "" }) |> result.unwrap(""))
  }
}
