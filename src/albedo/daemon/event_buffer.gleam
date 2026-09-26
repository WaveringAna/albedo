//// A contiguous replay window. Appends evict only what exceeds the budget;
//// they never walk or copy the whole window for every streamed token.

import gleam/dict.{type Dict}
import gleam/int
import gleam/string

pub opaque type Buffer {
  Buffer(oldest: Int, entries: Dict(Int, String), bytes: Int)
}

pub fn new() -> Buffer {
  Buffer(1, dict.new(), 0)
}

/// The session supplies consecutive sequence numbers, starting at one.
pub fn push(buffer: Buffer, sequence: Int, event: String) -> Buffer {
  let size = string.byte_size(event)
  case size > 4_194_304 {
    // An unretained event is a gap: even a client one event behind must reset.
    True -> Buffer(sequence + 1, dict.new(), 0)
    False ->
      trim(Buffer(
        buffer.oldest,
        dict.insert(buffer.entries, sequence, event),
        buffer.bytes + size,
      ))
  }
}

fn trim(buffer: Buffer) -> Buffer {
  case dict.size(buffer.entries) > 256 || buffer.bytes > 4_194_304 {
    False -> buffer
    True -> {
      let assert Ok(event) = dict.get(buffer.entries, buffer.oldest)
      trim(Buffer(
        buffer.oldest + 1,
        dict.delete(buffer.entries, buffer.oldest),
        buffer.bytes - string.byte_size(event),
      ))
    }
  }
}

/// Events in wire order, or a gap requiring a durable transcript reset.
pub fn since(
  buffer: Buffer,
  after: Int,
  sequence: Int,
) -> Result(List(String), Nil) {
  case after < 0 || after > sequence || after < buffer.oldest - 1 {
    True -> Error(Nil)
    False ->
      Ok(
        int.range(sequence, after, [], fn(events, cursor) {
          let assert Ok(event) = dict.get(buffer.entries, cursor)
          [event, ..events]
        }),
      )
  }
}
