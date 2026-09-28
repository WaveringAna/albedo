//// OpenAI-facing view of ssevents; framing and limits belong to the library.

import gleam/list
import gleam/option
import gleam/result
import ssevents
import ssevents/error

pub type Parser =
  ssevents.DecodeState

pub type Event {
  Event(name: String, data: String)
}

pub type Error {
  EventTooLarge
  InvalidUtf8
  Malformed(String)
}

pub fn new(max_event_bytes: Int) -> Parser {
  ssevents.new_limits(
    max_line_bytes: max_event_bytes,
    max_event_bytes: max_event_bytes,
    max_data_lines: max_event_bytes,
    max_retry_value: 86_400_000,
  )
  |> ssevents.new_decoder_with_limits
}

pub fn feed(
  parser: Parser,
  chunk: BitArray,
) -> Result(#(Parser, List(Event)), Error) {
  ssevents.push(parser, chunk)
  |> result.map(fn(pair) { #(pair.0, events(pair.1)) })
  |> result.map_error(map_error)
}

/// ssevents flushes a final unterminated event. The protocol reducer must still
/// recognize an explicit OpenAI terminal event; EOF alone is never success.
pub fn finish(parser: Parser) -> Result(List(Event), Error) {
  ssevents.finish(parser)
  |> result.map(events)
  |> result.map_error(map_error)
}

fn events(items: List(ssevents.Item)) -> List(Event) {
  items
  |> ssevents.events_of
  |> list.map(fn(event) {
    Event(option.unwrap(ssevents.name_of(event), ""), ssevents.data_of(event))
  })
}

fn map_error(error: ssevents.SseError) -> Error {
  case error {
    error.InvalidUtf8 -> InvalidUtf8
    error.LineTooLong(_) | error.EventTooLarge(_) | error.TooManyDataLines(_) ->
      EventTooLarge
    other -> Malformed(ssevents.error_to_string(other))
  }
}
