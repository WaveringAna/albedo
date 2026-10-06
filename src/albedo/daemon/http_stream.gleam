//// Bounded SSE writes. Stream owners acknowledge a source cursor only after
//// this module reports that its entire batch reached the socket.

import albedo/daemon/http_api
import albedo/daemon/http_coding
import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/result
import gleam/string
import mist

/// One stream's socket and content coding.
pub opaque type Writer {
  Writer(connection: mist.Connection, coding: http_coding.Stream)
}

/// Whether the stream for this request is zstd-coded. The handler decides,
/// since it sends the headers.
pub fn coded(req: request.Request(a)) -> Bool {
  http_coding.accepts(req)
}

/// The stream process's writer; it must create its own coding.
pub fn writer(req: request.Request(mist.Connection), coded: Bool) -> Writer {
  Writer(req.body, http_coding.start(coded))
}

pub fn response(
  req: request.Request(a),
  coded: Bool,
) -> response.Response(Nil) {
  let response =
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_header("cache-control", "no-store")
    |> response.set_header("x-accel-buffering", "no")
    |> response.set_header("vary", "Accept, Accept-Encoding")
    |> response.set_body(Nil)
  let response = case coded {
    True -> response.set_header(response, "content-encoding", "zstd")
    False -> response
  }
  // Streaming sends its headers before ordinary outer response decorators.
  // Ingress has already verified any Origin carried by this request.
  case request.get_header(req, "origin") {
    Error(_) -> response
    Ok(origin) ->
      response
      |> response.set_header("access-control-allow-origin", origin)
      |> response.set_header(
        "access-control-expose-headers",
        "ETag, Location, Retry-After",
      )
      |> response.set_header("vary", "Origin, Accept, Accept-Encoding")
  }
}

@external(erlang, "albedo_http_api", "stream_socket")
fn bounded_socket(connection: mist.Connection) -> Result(Nil, String)

pub fn configure(connection: mist.Connection) -> Result(Nil, http_api.Failure) {
  bounded_socket(connection)
  |> result.map_error(fn(_) {
    http_api.Failure(
      503,
      "stream_unavailable",
      "stream socket could not be configured",
    )
  })
}

pub fn send(writer: Writer, encoded: String) -> Result(Nil, Nil) {
  case string.byte_size(encoded) <= http_api.response_limit {
    False -> Error(Nil)
    True -> write(writer, "data: " <> encoded <> "\n\n")
  }
}

pub fn keepalive(writer: Writer) -> Result(Nil, Nil) {
  write(writer, ": keepalive\n\n")
}

/// Ends the coded frame before a stream stops on its own terms.
pub fn close(writer: Writer) -> Nil {
  case http_coding.close(writer.coding) {
    Ok(tail) -> {
      let _ = mist.send_chunk(writer.connection, tail)
      Nil
    }
    Error(_) -> Nil
  }
}

fn write(writer: Writer, frame: String) -> Result(Nil, Nil) {
  mist.send_chunk(
    writer.connection,
    http_coding.chunk(writer.coding, bit_array.from_string(frame)),
  )
}
