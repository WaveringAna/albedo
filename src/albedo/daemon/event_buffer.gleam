//// A contiguous replay window. Appends evict only what exceeds the budget;
//// they never walk or copy the whole window for every streamed token.

import gleam/dict.{type Dict}
import gleam/int
import gleam/json
import gleam/string

/// Every replay must fit one response (1 MiB) with room for the batch's own
/// fields, so the window keeps no more bytes than this.
pub const budget = 1_015_808

pub opaque type Buffer {
  Buffer(oldest: Int, entries: Dict(Int, #(json.Json, Int)), bytes: Int)
}

pub fn new() -> Buffer {
  Buffer(1, dict.new(), 0)
}

/// The session supplies consecutive sequence numbers, starting at one.
pub fn push(buffer: Buffer, sequence: Int, event: json.Json) -> Buffer {
  // Kept encoded: one binary is a fraction of the iodata tree it came as.
  let event = encoded(event)
  let size = string.byte_size(json.to_string(event))
  case size > budget {
    // An unretained event is a gap: even a client one event behind must reset.
    True -> Buffer(sequence + 1, dict.new(), 0)
    False ->
      trim(Buffer(
        buffer.oldest,
        dict.insert(buffer.entries, sequence, #(event, size)),
        buffer.bytes + size,
      ))
  }
}

fn trim(buffer: Buffer) -> Buffer {
  case dict.size(buffer.entries) > 256 || buffer.bytes > budget {
    False -> buffer
    True -> {
      let assert Ok(#(_, size)) = dict.get(buffer.entries, buffer.oldest)
      trim(Buffer(
        buffer.oldest + 1,
        dict.delete(buffer.entries, buffer.oldest),
        buffer.bytes - size,
      ))
    }
  }
}

/// The event as one binary, which is still a valid `Json` on Erlang.
@external(erlang, "erlang", "iolist_to_binary")
fn encoded(event: json.Json) -> json.Json

/// Events in wire order, or a gap requiring a durable transcript reset.
pub fn since(
  buffer: Buffer,
  after: Int,
  sequence: Int,
) -> Result(List(json.Json), Nil) {
  case after < 0 || after > sequence || after < buffer.oldest - 1 {
    True -> Error(Nil)
    False ->
      Ok(
        int.range(sequence, after, [], fn(events, cursor) {
          let assert Ok(#(event, _)) = dict.get(buffer.entries, cursor)
          [event, ..events]
        }),
      )
  }
}
