//// Unicode scalar limits, independent of grapheme boundaries.

import gleam/bit_array
import gleam/int

pub fn length(text: String) -> Int {
  count(<<text:utf8>>, 0)
}

fn count(bytes: BitArray, total: Int) -> Int {
  case bytes {
    <<_:utf8_codepoint, rest:bytes>> -> count(rest, total + 1)
    _ -> total
  }
}

pub fn take(text: String, count: Int) -> String {
  let bytes = <<text:utf8>>
  let rest = skip(bytes, int.max(0, count))
  let size = bit_array.byte_size(bytes) - bit_array.byte_size(rest)
  let assert <<prefix:bytes-size(size), _:bytes>> = bytes
  copied_text(prefix)
}

pub fn drop(text: String, count: Int) -> String {
  copied_text(skip(<<text:utf8>>, int.max(0, count)))
}

pub fn tail(text: String, count: Int) -> String {
  drop(text, int.max(0, length(text) - int.max(0, count)))
}

fn skip(bytes: BitArray, count: Int) -> BitArray {
  case count, bytes {
    0, _ -> bytes
    _, <<_:utf8_codepoint, rest:bytes>> -> skip(rest, count - 1)
    _, _ -> <<>>
  }
}

// A bounded preview must not keep its source binary alive.
@external(erlang, "binary", "copy")
fn copy(bytes: BitArray) -> BitArray

fn copied_text(bytes: BitArray) -> String {
  let assert Ok(text) = bit_array.to_string(copy(bytes))
  text
}
