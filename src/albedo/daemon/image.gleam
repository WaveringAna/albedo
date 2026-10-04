import albedo/openai_api/types
import gleam/bit_array
import gleam/int
import gleam/result
import gleam/string

/// Decode canonical base64 and derive MIME and dimensions from bounded headers.
/// This verifies transport metadata, not the complete compressed image stream.
pub fn validate(
  mime_type: String,
  data: String,
  width: Int,
  height: Int,
  bytes: Int,
) -> Result(types.Image, String) {
  use image <- result.try(
    types.image(mime_type, data, width, height, bytes)
    |> result.map_error(string.inspect),
  )
  use inspected <- result.try(
    inspect(data)
    |> result.replace_error("invalid image payload or header"),
  )
  case inspected == #(mime_type, width, height, bytes) {
    True -> Ok(image)
    False -> Error("image metadata does not match its payload")
  }
}

/// An image whose MIME type and dimensions are read from its own header.
pub fn from_base64(data: String) -> Result(types.Image, String) {
  use #(mime_type, width, height, bytes) <- result.try(
    inspect(data)
    |> result.replace_error("not a PNG, JPEG, or WebP albedo can read"),
  )
  types.image(mime_type, data, width, height, bytes)
  |> result.map_error(fn(error) {
    case error {
      types.InvalidRequest(message) -> message
      other -> string.inspect(other)
    }
  })
}

const max_data_bytes = 6_990_508

const header_chars = 65_536

/// Inspect transport data without copying it to re-encode canonical base64.
pub fn inspect(data: String) -> Result(#(String, Int, Int, Int), Nil) {
  use size <- result.try(canonical_size(data))
  use #(mime, width, height) <- result.try(dimensions(decode_base64(data)))
  Ok(#(mime, width, height, size))
}

/// Legacy inline rows are validated on every transcript load. Decode only a
/// header prefix when possible; WebP needs the whole RIFF size and JPEG may
/// place its frame header beyond the prefix.
pub fn valid_payload(
  mime: String,
  data: String,
  width: Int,
  height: Int,
  bytes: Int,
) -> Bool {
  case canonical_size(data) {
    Ok(size) if size == bytes ->
      header_dimensions(data) == Ok(#(mime, width, height))
    _ -> False
  }
}

fn header_dimensions(data: String) -> Result(#(String, Int, Int), Nil) {
  case <<data:utf8>> {
    <<prefix:bytes-size(header_chars), rest:bytes>> if rest != <<>> ->
      case dimensions(decode_base64(as_text(prefix))) {
        Ok(#("image/webp", _, _)) | Error(_) -> dimensions(decode_base64(data))
        found -> found
      }
    _ -> dimensions(decode_base64(data))
  }
}

@external(erlang, "albedo_images", "decode_base64")
fn decode_base64(data: String) -> BitArray

// The slice consists of complete four-character base64 quads.
@external(erlang, "gleam_stdlib", "identity")
fn as_text(bytes: BitArray) -> String

fn canonical_size(data: String) -> Result(Int, Nil) {
  let size = string.byte_size(data)
  case size >= 4 && size <= max_data_bytes && size % 4 == 0 {
    False -> Error(Nil)
    True -> {
      let body = size - 4
      let assert <<head:bytes-size(body), last:bytes>> = <<data:utf8>>
      case charset(head, False), last {
        True, <<first, second, 61, 61>> ->
          quad_tail(<<first, second>>, second, 15, 1, body)
        True, <<first, second, third, 61>> ->
          quad_tail(<<first, second, third>>, third, 3, 2, body)
        True, <<_, _, _, fourth>> -> quad_tail(last, fourth, 0, 3, body)
        _, _ -> Error(Nil)
      }
    }
  }
}

fn quad_tail(
  prefix: BitArray,
  last: Int,
  mask: Int,
  extra: Int,
  body: Int,
) -> Result(Int, Nil) {
  let size = body / 4 * 3 + extra
  case
    charset(prefix, False)
    && int.bitwise_and(base64_value(last), mask) == 0
    && size <= types.max_image_bytes
  {
    True -> Ok(size)
    False -> Error(Nil)
  }
}

/// Stored payloads must need no JSON escaping. Padding may occur anywhere
/// here; canonical transport validation uses the stricter size check above.
pub fn safe_payload(data: String) -> Bool {
  charset(<<data:utf8>>, True)
}

fn charset(bytes: BitArray, padding: Bool) -> Bool {
  case bytes {
    <<char, rest:bytes>>
      if char >= 65
      && char <= 90
      || char >= 97
      && char <= 122
      || char >= 48
      && char <= 57
      || char == 43
      || char == 47
    -> charset(rest, padding)
    <<61, rest:bytes>> if padding -> charset(rest, padding)
    <<>> -> True
    _ -> False
  }
}

fn base64_value(char: Int) -> Int {
  case char {
    char if char >= 65 && char <= 90 -> char - 65
    char if char >= 97 && char <= 122 -> char - 97 + 26
    char if char >= 48 && char <= 57 -> char - 48 + 52
    43 -> 62
    _ -> 63
  }
}

fn dimensions(bytes: BitArray) -> Result(#(String, Int, Int), Nil) {
  case bytes {
    <<
      0x89,
      "PNG":utf8,
      13,
      10,
      26,
      10,
      13:size(32),
      "IHDR":utf8,
      width:size(32),
      height:size(32),
      _:bytes,
    >>
      if width > 0 && height > 0
    -> Ok(#("image/png", width, height))
    <<0xFF, 0xD8, rest:bytes>> -> jpeg(rest)
    <<"RIFF":utf8, size:little-size(32), "WEBP":utf8, chunks:bytes>> ->
      case size + 8 == bit_array.byte_size(bytes) {
        True -> webp(chunks)
        False -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

fn jpeg(bytes: BitArray) -> Result(#(String, Int, Int), Nil) {
  case bytes {
    <<0xFF, rest:bytes>> -> jpeg_marker(rest)
    <<_, rest:bytes>> -> jpeg(rest)
    _ -> Error(Nil)
  }
}

fn jpeg_marker(bytes: BitArray) -> Result(#(String, Int, Int), Nil) {
  case bytes {
    <<0xFF, rest:bytes>> -> jpeg_marker(rest)
    <<marker, rest:bytes>>
      if marker == 0xD8 || marker == 0x01 || marker >= 0xD0 && marker <= 0xD7
    -> jpeg(rest)
    <<marker, size:size(16), rest:bytes>> if size >= 2 -> {
      case rest {
        <<payload:bytes-size(size - 2), tail:bytes>> ->
          case marker {
            0xC0
            | 0xC1
            | 0xC2
            | 0xC3
            | 0xC5
            | 0xC6
            | 0xC7
            | 0xC9
            | 0xCA
            | 0xCB
            | 0xCD
            | 0xCE
            | 0xCF ->
              case payload {
                <<_, height:size(16), width:size(16), _:bytes>>
                  if width > 0 && height > 0
                -> Ok(#("image/jpeg", width, height))
                _ -> Error(Nil)
              }
            0xDA | 0xD9 -> Error(Nil)
            _ -> jpeg(tail)
          }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn webp(bytes: BitArray) -> Result(#(String, Int, Int), Nil) {
  case bytes {
    <<
      "VP8X":utf8,
      10:little-size(32),
      _,
      _:size(24),
      width:little-size(24),
      height:little-size(24),
      _:bytes,
    >> -> Ok(#("image/webp", width + 1, height + 1))
    <<"VP8L":utf8, size:little-size(32), 0x2F, bits:little-size(32), _:bytes>>
      if size >= 5
    ->
      Ok(#(
        "image/webp",
        int.bitwise_and(bits, 0x3FFF) + 1,
        int.bitwise_and(int.bitwise_shift_right(bits, 14), 0x3FFF) + 1,
      ))
    <<
      "VP8 ":utf8,
      size:little-size(32),
      _:size(24),
      0x9D,
      0x01,
      0x2A,
      width_bits:little-size(16),
      height_bits:little-size(16),
      _:bytes,
    >>
      if size >= 10
    -> {
      let width = int.bitwise_and(width_bits, 0x3FFF)
      let height = int.bitwise_and(height_bits, 0x3FFF)
      case width > 0 && height > 0 {
        True -> Ok(#("image/webp", width, height))
        False -> Error(Nil)
      }
    }
    <<
      _:bytes-size(4),
      size:little-size(32),
      _:bytes-size(size),
      _:bytes-size(size % 2),
      tail:bytes,
    >> -> webp(tail)
    _ -> Error(Nil)
  }
}
