// Incremental SSE parsing must handle byte splits, UTF-8 boundaries, limits, and EOF independently of HTTP chunking.
import albedo/openai_api/sse
import gleam/list
import gleam/result

pub fn library_handles_split_utf8_bom_and_crlf_test() -> Nil {
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

pub fn configured_limits_reach_library_test() -> Nil {
  assert sse.feed(sse.new(7), <<"data: xx">>) == Error(sse.EventTooLarge)
  assert sse.feed(sse.new(7), <<":1234567">>) == Error(sse.EventTooLarge)
}

pub fn invalid_utf8_is_a_typed_error_test() -> Nil {
  assert sse.feed(sse.new(1024), <<"data: ":utf8, 0xFF, "\n\n":utf8>>)
    == Error(sse.InvalidUtf8)
}

pub fn library_flushes_unterminated_event_test() -> Nil {
  let assert Ok(#(parser, [])) = sse.feed(sse.new(1024), <<"data: [DONE]">>)
  assert sse.finish(parser) == Ok([sse.Event("", "[DONE]")])
}

fn bytes(input: BitArray) -> List(BitArray) {
  case input {
    <<byte, rest:bytes>> -> [<<byte>>, ..bytes(rest)]
    _ -> []
  }
}
