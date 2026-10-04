//// Catches framing bugs at exact byte splits that HTTP E2E cannot control.

import albedo/openai_api/sse
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub fn split_utf8_bom_and_crlf_test() -> Nil {
  let input = <<
    0xEF,
    0xBB,
    0xBF,
    ": heartbeat\r\nevent: update\r\ndata: hé\r\ndata: world\r\n\r\n":utf8,
  >>
  let chunks = bytes(input)
  let assert Ok(#(_, events)) =
    list.try_fold(chunks, #(sse.new(1024), []), fn(acc, chunk) {
      let #(parser, events) = acc
      use #(parser, next) <- result.try(sse.feed(parser, chunk))
      Ok(#(parser, list.append(events, next)))
    })
  assert events == [sse.Event("update", "hé\nworld")]
}

pub fn configured_limits_reject_incomplete_lines_test() -> Nil {
  assert sse.feed(sse.new(7), <<"data: xx">>) == Error(sse.EventTooLarge)
  assert sse.feed(sse.new(7), <<":1234567">>) == Error(sse.EventTooLarge)
}

pub fn invalid_utf8_is_a_typed_error_test() -> Nil {
  assert sse.feed(sse.new(1024), <<"data: ":utf8, 0xFF, "\n\n":utf8>>)
    == Error(sse.InvalidUtf8)
}

pub fn non_byte_aligned_input_is_a_typed_error_test() -> Nil {
  assert sse.feed(sse.new(1024), <<1:size(1)>>) == Error(sse.InvalidUtf8)
  let assert Ok(#(parser, [])) = sse.feed(sse.new(1024), <<"data: ">>)
  assert sse.feed(parser, <<1:size(1)>>) == Error(sse.InvalidUtf8)
}

pub fn flushes_unterminated_event_test() -> Nil {
  let assert Ok(#(parser, [])) = sse.feed(sse.new(1024), <<"data: [DONE]">>)
  assert sse.finish(parser) == Ok([sse.Event("", "[DONE]")])
}

fn bytes(input: BitArray) -> List(BitArray) {
  case input {
    <<byte, rest:bytes>> -> [<<byte>>, ..bytes(rest)]
    _ -> []
  }
}

pub fn every_two_chunk_partition_preserves_events_test() -> Nil {
  let input = <<
    0xEF,
    0xBB,
    0xBF,
    "event: update\rdata:  \u{0301}hé\r\ndata: two\nignored: value\nid: bad\u{0000}\nretry: invalid\n\rdata\r\rdata: last":utf8,
  >>
  let expected = [
    sse.Event("update", " \u{0301}hé\ntwo"),
    sse.Event("", ""),
    sse.Event("", "last"),
  ]
  int.range(0, bit_array.byte_size(input), with: Nil, run: fn(_, offset) {
    let assert Ok(first) = bit_array.slice(input, 0, offset)
    let assert Ok(second) =
      bit_array.slice(input, offset, bit_array.byte_size(input) - offset)
    assert decode_chunks([first, <<>>, second], 1024) == Ok(expected)
  })
  assert decode_chunks(bytes(input), 1024) == Ok(expected)
}

pub fn large_fragmented_line_is_assembled_without_changing_data_test() -> Nil {
  let payload = string.repeat("hé", 30_000)
  let input = bit_array.from_string("data: " <> payload <> "\n\n")
  assert decode_chunks(bytes(input), 100_000) == Ok([sse.Event("", payload)])
}

pub fn event_budget_counts_unknown_fields_but_excludes_comments_test() -> Nil {
  assert decode_chunks([<<": long comment\ndata: x\n\n">>], 14)
    == Ok([sse.Event("", "x")])
  assert decode_chunks([<<"data: x\nunknown\n\n">>], 13)
    == Error(sse.EventTooLarge)
}

pub fn malformed_event_name_and_split_invalid_utf8_test() -> Nil {
  let assert Error(sse.Malformed(_)) =
    decode_chunks([<<"event: bad":utf8, 0, "\ndata: x\n\n":utf8>>], 1024)
  assert decode_chunks([<<"data: ":utf8, 0xC3>>, <<"\n\n">>], 1024)
    == Error(sse.InvalidUtf8)
}

pub fn trailing_cr_and_exact_line_limit_test() -> Nil {
  assert decode_chunks([<<"data: x\r">>], 7) == Ok([sse.Event("", "x")])
  assert decode_chunks([<<"data: x">>, <<"x">>], 7) == Error(sse.EventTooLarge)
}

fn decode_chunks(
  chunks: List(BitArray),
  limit: Int,
) -> Result(List(sse.Event), sse.Error) {
  use #(parser, events) <- result.try(
    list.try_fold(chunks, #(sse.new(limit), []), fn(acc, chunk) {
      use #(parser, next) <- result.try(sse.feed(acc.0, chunk))
      Ok(#(parser, list.append(acc.1, next)))
    }),
  )
  use trailing <- result.try(sse.finish(parser))
  Ok(list.append(events, trailing))
}

pub fn bom_is_only_stripped_at_stream_start_test() -> Nil {
  assert decode_chunks(
      [
        <<>>,
        <<0xEF>>,
        <<>>,
        <<0xBB>>,
        <<0xBF>>,
        <<"data: ":utf8, 0xEF, 0xBB, 0xBF, "x\n\n":utf8>>,
      ],
      1024,
    )
    == Ok([sse.Event("", "\u{FEFF}x")])
  assert decode_chunks([<<>>, <<0xEF>>, <<0xBB>>, <<>>], 1024)
    == Error(sse.InvalidUtf8)
  assert decode_chunks([<<>>, <<>>], 1024) == Ok([])
}

pub fn fields_split_only_the_first_colon_and_strip_one_ascii_space_test() -> Nil {
  let assert Ok(#(_, events)) =
    sse.feed(sse.new(1024), <<
      "data:  first: second\ndata:\tthird\ndata\n\n":utf8,
    >>)
  assert events == [sse.Event("", " first: second\n\tthird\n")]
}

pub fn a_combining_mark_after_the_colon_is_field_data_test() -> Nil {
  let assert Ok(#(_, events)) =
    sse.feed(sse.new(1024), <<
      "event:\u{0301}update\ndata:\u{0301}: value\n\n":utf8,
    >>)
  assert events == [sse.Event("\u{0301}update", "\u{0301}: value")]
}
