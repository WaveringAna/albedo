//// Scalar and grapheme limits differ on combining marks. E2E cannot inspect
//// retained binary size or exhaust exact slicing boundaries deterministically.

import albedo/daemon/session_configuration
import albedo/text_scalars
import gleam/option.{Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_text_scalars_test_support", "referenced_size")
fn referenced_size(text: String) -> Int

pub fn scalar_slices_preserve_combining_marks_and_utf8_boundaries_test() -> Nil {
  let text = "a\u{0301}😀z"
  text_scalars.length(text) |> should.equal(4)
  text_scalars.take(text, 2) |> should.equal("a\u{0301}")
  text_scalars.drop(text, 2) |> should.equal("😀z")
  text_scalars.tail(text, 2) |> should.equal("😀z")
  text_scalars.take(text, -1) |> should.equal("")
  text_scalars.drop(text, -1) |> should.equal(text)
  text_scalars.tail(text, -1) |> should.equal("")
  text_scalars.drop(text, 10) |> should.equal("")
  text_scalars.take("", 2) |> should.equal("")
  let large = string.repeat("😀", 100_000)
  let prefix = text_scalars.take(large, 1)
  let suffix = text_scalars.tail(large, 1)
  referenced_size(prefix) |> should.equal(4)
  referenced_size(suffix) |> should.equal(4)
}

pub fn names_mask_controls_and_limit_scalars_without_splitting_marks_test() -> Nil {
  session_configuration.clean_name(
    " a\u{0000}\u{0085}\u{00AD}\u{200B}\u{200E}\u{2028}\u{2060}\u{FEFF} b ",
  )
  |> should.equal(Some("a b"))
  let text = "x" <> string.repeat("\u{0301}", 5000)
  let assert Some(clean) = session_configuration.clean_name(text)
  text_scalars.length(clean) |> should.equal(4096)
  clean |> should.equal("x" <> string.repeat("\u{0301}", 4095))
}
