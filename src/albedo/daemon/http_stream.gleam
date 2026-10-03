//// Bounded SSE writes. Stream owners acknowledge a source cursor only after
//// this module reports that its entire batch reached the socket.

import albedo/daemon/http_api
import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/result
import gleam/string
import mist

pub fn response(req: request.Request(a)) -> response.Response(Nil) {
  let response =
    response.new(200)
    |> response.set_header("content-type", "text/event-stream")
    |> response.set_header("cache-control", "no-store")
    |> response.set_header("x-accel-buffering", "no")
    |> response.set_header("vary", "Accept")
    |> response.set_body(Nil)
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
      |> response.set_header("vary", "Origin, Accept")
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

pub fn send(connection: mist.Connection, encoded: String) -> Result(Nil, Nil) {
  case string.byte_size(encoded) <= http_api.response_limit {
    False -> Error(Nil)
    True ->
      mist.send_chunk(
        connection,
        bit_array.from_string("data: " <> encoded <> "\n\n"),
      )
  }
}

pub fn keepalive(connection: mist.Connection) -> Result(Nil, Nil) {
  mist.send_chunk(connection, bit_array.from_string(": keepalive\n\n"))
}
