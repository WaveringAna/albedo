//// Unicode scalar limits, independent of grapheme boundaries.

import gleam/bit_array
import gleam/int
import gleam/string

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
  // A scalar is at least a byte, so text this short is already its own tail.
  case string.byte_size(text) <= count {
    True -> copy_text(text)
    False -> drop(text, int.max(0, length(text) - int.max(0, count)))
  }
}

fn skip(bytes: BitArray, count: Int) -> BitArray {
  case count, bytes {
    0, _ -> bytes
    _, <<_:utf8_codepoint, rest:bytes>> -> skip(rest, count - 1)
    _, _ -> <<>>
  }
}

// A bounded preview must not keep its source binary alive. The bytes are a
// slice of valid text at scalar boundaries, so the copy is valid text too.
@external(erlang, "binary", "copy")
fn copied_text(bytes: BitArray) -> String

@external(erlang, "binary", "copy")
fn copy_text(text: String) -> String
