//// The kernel reads image headers itself so `show_image` can refuse an image
//// over the model's edge at the call, and the daemon reads them again as the
//// authority. Two parsers in two languages drift apart silently, and E2E only
//// ever sends one well-formed PNG, so these fixtures hold both to one answer.

import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit/should

@external(erlang, "albedo_image", "inspect")
fn inspect(data: String) -> Result(#(String, Int, Int, Int), Nil)

/// Name, canonical base64, and the MIME type and size its header says.
const fixtures = [
  #(
    "png",
    "iVBORw0KGgoAAAANSUhEUgAACQAAAAS8CAIAAAA=",
    Some(#("image/png", 2304, 1212)),
  ),
  #("png zero width", "iVBORw0KGgoAAAANSUhEUgAAAAAAAAAFCAIAAAA=", None),
  #("png truncated", "iVBORw0KGgoAAAANSUhEUgAAAAM=", None),
  #(
    "jpeg baseline",
    "/9j/4AAQSkZJRgABAQAAAQABAAD/wAAICAHgAoAD/9k=",
    Some(#("image/jpeg", 640, 480)),
  ),
  #("jpeg progressive", "/9j/wgAICAu4D6AD", Some(#("image/jpeg", 4000, 3000))),
  #(
    "jpeg fill bytes and restart",
    "/9j/0P///+AAEEpGSUYAAQEAAAEAAQAAAAD/wQAICAAJAAcD",
    Some(#("image/jpeg", 7, 9)),
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
    #(fixture.0, case inspect(fixture.1) {
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
      "import base64, json, sys\nsize = sys.modules['__main__'].image_size\n"
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
