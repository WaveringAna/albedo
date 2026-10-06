//// The kernel reads image headers itself so `show_image` can refuse an image
//// over the model's edge, or one cut short, at the call, and the daemon reads
//// them again as the authority. Two parsers in two languages drift apart
//// silently, and E2E only ever sends one well-formed PNG, so these fixtures
//// hold both to one answer.

import albedo/daemon/image
import albedo/openai_api/types

import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import gleam/bit_array
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should

/// Name, canonical base64, and the MIME type and size its header says.
const fixtures = [
  #(
    "png",
    "iVBORw0KGgoAAAANSUhEUgAACQAAAAS8CAIAAABW4yLdAAAAAElFTkSuQmCC",
    Some(#("image/png", 2304, 1212)),
  ),
  #(
    "png bytes after iend",
    "iVBORw0KGgoAAAANSUhEUgAACQAAAAS8CAIAAABW4yLdAAAAAElFTkSuQmCCdGFpbA==",
    Some(#("image/png", 2304, 1212)),
  ),
  #(
    "png stops before iend",
    "iVBORw0KGgoAAAANSUhEUgAACQAAAAS8CAIAAABW4yLd",
    None,
  ),
  #("png header only", "iVBORw0KGgoAAAANSUhEUgAACQAAAAS8CAIAAAA=", None),
  #("png zero width", "iVBORw0KGgoAAAANSUhEUgAAAAAAAAAFCAIAAAA=", None),
  #("png truncated", "iVBORw0KGgoAAAANSUhEUgAAAAM=", None),
  #(
    "jpeg baseline",
    "/9j/4AAQSkZJRgABAQAAAQABAAD/wAAICAHgAoAD/9k=",
    Some(#("image/jpeg", 640, 480)),
  ),
  #(
    "jpeg progressive",
    "/9j/wgAICAu4D6AD/9k=",
    Some(#("image/jpeg", 4000, 3000)),
  ),
  #(
    "jpeg fill bytes and restart",
    "/9j/0P///+AAEEpGSUYAAQEAAAEAAQAAAAD/wQAICAAJAAcD/9k=",
    Some(#("image/jpeg", 7, 9)),
  ),
  #(
    "jpeg without end of image",
    "/9j/4AAQSkZJRgABAQAAAQABAAD/wAAICAHgAoAD",
    None,
  ),
  #("jpeg scan before frame", "/9j/2gAEAAD/wAAICAABAAED", None),
  #("jpeg truncated segment", "/9j/4QAWeHh4eHh4", None),
  #("jpeg zero height", "/9j/wAAICAAAAAoD", None),
  #("jpeg short length", "/9j/4AAB/8AACAgAAgACAw==", None),
  #(
    "webp vp8x",
    "UklGRhYAAABXRUJQVlA4WAoAAAAAAAAAtwsAEwAA",
    Some(#("image/webp", 3000, 20)),
  ),
  #(
    "webp vp8l",
    "UklGRhIAAABXRUJQVlA4TAYAAAAvAMgDAAA=",
    Some(#("image/webp", 2049, 16)),
  ),
  #(
    "webp vp8",
    "UklGRhYAAABXRUJQVlA4IAoAAAAAAACdASqABzgE",
    Some(#("image/webp", 1920, 1080)),
  ),
  #(
    "webp chunk before image",
    "UklGRh4AAABXRUJQSUNDUAMAAABhYmMAVlA4TAYAAAAvBEABAAA=",
    Some(#("image/webp", 5, 6)),
  ),
  #(
    "webp vp8 without start code",
    "UklGRhYAAABXRUJQVlA4IAoAAAAAAAAAAAAFAAUA",
    None,
  ),
  #("webp riff size mismatch", "UklGRhIAAABXRUJQVlA4TAYAAAAvBEABAAAAAA==", None),
  #("webp no image chunk", "UklGRhAAAABXRUJQRVhJRgQAAABhYmNk", None),
  #("garbage", "bm90IGFuIGltYWdlIGF0IGFsbA==", None),
]

pub fn the_kernel_reads_image_headers_the_way_the_daemon_does_test() -> Nil {
  let expected = list.map(fixtures, fn(fixture) { #(fixture.0, fixture.2) })
  list.map(fixtures, fn(fixture) {
    #(fixture.0, case image.inspect(fixture.1) {
      Ok(#(mime, width, height, _)) -> Some(#(mime, width, height))
      Error(_) -> None
    })
  })
  |> should.equal(expected)

  let assert Ok(store) = work.start(":memory:")
  let assert Ok(kernel) = python.local(store, "/tmp")
  let encoded = json.array(fixtures, fn(fixture) { json.string(fixture.1) })
  let assert Ok(read) =
    python.execute(
      kernel,
      "headers",
      "import base64, json\nfrom albedo_capture import image_size as size\n"
        <> "for data in json.loads("
        <> string.inspect(json.to_string(encoded))
        <> "):\n    print(json.dumps(size(base64.b64decode(data))))",
      10_000,
    )
  list.zip(
    list.map(fixtures, fn(fixture) { fixture.0 }),
    string.split(string.trim_end(read.output), "\n"),
  )
  |> should.equal(
    list.map(expected, fn(pair) { #(pair.0, header_json(pair.1)) }),
  )
  let assert Ok(_) = python.stop(kernel)
  work.close(store)
}

fn header_json(header: Option(#(String, Int, Int))) -> String {
  case header {
    Some(#(mime, width, height)) ->
      "[\""
      <> mime
      <> "\", "
      <> int.to_string(width)
      <> ", "
      <> int.to_string(height)
      <> "]"
    None -> "null"
  }
}

@external(erlang, "albedo_images", "encode_base64")
fn encode_base64(bytes: BitArray) -> String

/// A whole 2x3 PNG: signature, IHDR, and IEND, in 45 bytes.
const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAAElFTkSuQmCC"

pub fn canonical_base64_and_metadata_must_agree_test() -> Nil {
  image.inspect(png <> "AA==") |> should.equal(Ok(#("image/png", 2, 3, 46)))
  image.inspect(png <> "AB==") |> should.equal(Error(Nil))
  image.inspect(png <> "AAA=") |> should.equal(Ok(#("image/png", 2, 3, 47)))
  image.inspect(png <> "AAB=") |> should.equal(Error(Nil))
  image.inspect(png <> "AA==AAAA") |> should.equal(Error(Nil))
  image.valid_payload("image/png", png, 2, 3, 45) |> should.be_true
  image.valid_payload("image/png", png, 2, 4, 45) |> should.be_false
  image.valid_payload("image/jpeg", png, 2, 3, 45) |> should.be_false
  image.valid_payload("image/png", png, 2, 3, 46) |> should.be_false
}

pub fn late_jpeg_headers_and_webp_riff_sizes_require_full_decode_test() -> Nil {
  let padding = bit_array.from_string(string.repeat("x", 60_000))
  let jpeg = <<
    0xFF,
    0xD8,
    0xFF,
    0xE0,
    60_002:size(16),
    padding:bits,
    0xFF,
    0xC0,
    8:size(16),
    8,
    3:size(16),
    2:size(16),
    3,
  >>
  let data = encode_base64(jpeg)
  image.valid_payload("image/jpeg", data, 2, 3, bit_array.byte_size(jpeg))
  |> should.be_true
  let chunks = <<
    "JUNK":utf8,
    60_000:little-size(32),
    padding:bits,
    "VP8L":utf8,
    6:little-size(32),
    0x2F,
    81_924:little-size(32),
    0,
  >>
  let size = 4 + bit_array.byte_size(chunks)
  let webp = <<"RIFF":utf8, size:little-size(32), "WEBP":utf8, chunks:bits>>
  image.valid_payload(
    "image/webp",
    encode_base64(webp),
    5,
    6,
    bit_array.byte_size(webp),
  )
  |> should.be_true
  let bad_size = <<"RIFF":utf8, 4:little-size(32), "WEBP":utf8, chunks:bits>>
  image.inspect(encode_base64(bad_size)) |> should.equal(Error(Nil))
}

pub fn canonical_payload_size_enforces_the_decoded_limit_test() -> Nil {
  let assert Ok(whole) = bit_array.base64_decode(png)
  let tail = types.max_image_bytes - bit_array.byte_size(whole)
  let padding = bit_array.from_string(string.repeat("x", tail))
  let bytes = <<whole:bits, padding:bits>>
  image.inspect(encode_base64(bytes))
  |> should.equal(Ok(#("image/png", 2, 3, types.max_image_bytes)))
  image.inspect(encode_base64(<<bytes:bits, 0>>)) |> should.equal(Error(Nil))
}
