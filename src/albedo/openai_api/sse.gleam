//// Incremental framing. Only newly received bytes are searched for line endings.

import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string

pub opaque type Parser {
  Parser(
    fragments: List(BitArray),
    line_bytes: Int,
    pending_cr: Bool,
    bom_prefix: BitArray,
    bom_handled: Bool,
    name: String,
    data: List(String),
    event_bytes: Int,
    limit: Int,
  )
}

pub type Event {
  Event(name: String, data: String)
}

pub type Error {
  EventTooLarge
  InvalidUtf8
  Malformed(String)
}

@external(erlang, "albedo_sse_bytes", "newline")
fn newline(bytes: BitArray) -> Int

@external(erlang, "albedo_sse_bytes", "compact")
fn compact(bytes: BitArray) -> BitArray

/// A completed line as a string; the UTF-8 check runs natively rather than
/// one codepoint per call, as `bit_array.to_string` does.
@external(erlang, "albedo_sse_bytes", "utf8")
fn utf8(bytes: BitArray) -> Result(String, Nil)

fn field(line: String) -> #(String, String) {
  // Only these fields are consumed. Byte prefixes also match a colon followed
  // by a combining mark, which grapheme-aware string splitting would skip.
  let #(name, value) = case line {
    "data:" <> value -> #("data", value)
    "event:" <> value -> #("event", value)
    _ -> #(line, "")
  }
  #(name, case value {
    " " <> rest -> rest
    _ -> value
  })
}

pub fn new(max_event_bytes: Int) -> Parser {
  case max_event_bytes < 1 {
    True -> panic as "max_event_bytes must be >= 1"
    False -> Nil
  }
  Parser([], 0, False, <<>>, False, "", [], 0, max_event_bytes)
}

pub fn feed(
  parser: Parser,
  chunk: BitArray,
) -> Result(#(Parser, List(Event)), Error) {
  use _ <- result.try(case bit_array.bit_size(chunk) % 8 {
    0 -> Ok(Nil)
    _ -> Error(InvalidUtf8)
  })
  case parser.bom_handled {
    True -> resume(parser, chunk, [])
    False -> {
      let bytes = case parser.bom_prefix {
        <<>> -> chunk
        prefix -> bit_array.append(prefix, chunk)
      }
      case bytes {
        <<>> | <<0xEF>> | <<0xEF, 0xBB>> ->
          Ok(#(Parser(..parser, bom_prefix: compact(bytes)), []))
        <<0xEF, 0xBB, 0xBF, rest:bytes>> ->
          resume(
            Parser(..parser, bom_prefix: <<>>, bom_handled: True),
            rest,
            [],
          )
        _ ->
          resume(
            Parser(..parser, bom_prefix: <<>>, bom_handled: True),
            bytes,
            [],
          )
      }
    }
  }
}

fn resume(
  parser: Parser,
  chunk: BitArray,
  events: List(Event),
) -> Result(#(Parser, List(Event)), Error) {
  case parser.pending_cr, chunk {
    True, <<>> -> Ok(#(parser, list.reverse(events)))
    True, _ -> {
      use #(parser, events) <- result.try(complete_line(parser, events))
      let chunk = case chunk {
        <<10, rest:bytes>> -> rest
        _ -> chunk
      }
      scan(parser, chunk, events)
    }
    False, _ -> scan(parser, chunk, events)
  }
}

fn scan(
  parser: Parser,
  chunk: BitArray,
  events: List(Event),
) -> Result(#(Parser, List(Event)), Error) {
  let offset = newline(chunk)
  let length = case offset {
    -1 -> bit_array.byte_size(chunk)
    _ -> offset
  }
  case parser.line_bytes + length > parser.limit {
    True -> Error(EventTooLarge)
    False -> {
      let assert <<prefix:bytes-size(length), rest:bytes>> = chunk
      let fragments = case prefix {
        <<>> -> parser.fragments
        _ -> [compact(prefix), ..parser.fragments]
      }
      let parser =
        Parser(
          ..parser,
          fragments: fragments,
          line_bytes: parser.line_bytes + length,
        )
      case rest {
        <<>> -> Ok(#(parser, list.reverse(events)))
        <<13>> ->
          Ok(#(Parser(..parser, pending_cr: True), list.reverse(events)))
        _ -> {
          use #(parser, events) <- result.try(complete_line(parser, events))
          let rest = case rest {
            <<13, 10, tail:bytes>> -> tail
            <<_, tail:bytes>> -> tail
            _ -> <<>>
          }
          scan(parser, rest, events)
        }
      }
    }
  }
}

fn complete_line(
  parser: Parser,
  events: List(Event),
) -> Result(#(Parser, List(Event)), Error) {
  // A line that arrived in one chunk, as most do, is used without a copy.
  let bytes = case parser.fragments {
    [fragment] -> fragment
    fragments -> fragments |> list.reverse |> bit_array.concat
  }
  use line <- result.try(utf8(bytes) |> result.replace_error(InvalidUtf8))
  // Comments are free; every other line counts toward the event budget.
  let bytes = parser.event_bytes + parser.line_bytes
  let parser = Parser(..parser, fragments: [], line_bytes: 0, pending_cr: False)
  case line {
    "" -> Ok(dispatch(parser, events))
    ":" <> _ -> Ok(#(parser, events))
    _ if bytes > parser.limit -> Error(EventTooLarge)
    _ -> {
      let parser = Parser(..parser, event_bytes: bytes)
      case field(line) {
        #("data", value) ->
          Ok(#(Parser(..parser, data: [value, ..parser.data]), events))
        #("event", value) ->
          case string.contains(value, "\u{0000}") {
            True -> Error(Malformed("invalid SSE field: event"))
            False -> Ok(#(Parser(..parser, name: value), events))
          }
        _ -> Ok(#(parser, events))
      }
    }
  }
}

fn dispatch(parser: Parser, events: List(Event)) -> #(Parser, List(Event)) {
  let events = case parser.data {
    [] -> events
    [data] -> [Event(parser.name, data), ..events]
    data -> [
      Event(parser.name, data |> list.reverse |> string.join("\n")),
      ..events
    ]
  }
  #(Parser(..parser, name: "", data: [], event_bytes: 0), events)
}

/// EOF flushes a final unterminated event; reducers still require a terminal event.
pub fn finish(parser: Parser) -> Result(List(Event), Error) {
  let parser = case parser.bom_prefix {
    <<>> -> parser
    prefix ->
      Parser(
        ..parser,
        fragments: [prefix],
        line_bytes: bit_array.byte_size(prefix),
      )
  }
  case parser.line_bytes > 0 || parser.pending_cr {
    True -> {
      use #(parser, events) <- result.try(complete_line(parser, []))
      Ok(dispatch(parser, events).1 |> list.reverse)
    }
    False -> Ok(dispatch(parser, []).1 |> list.reverse)
  }
}
