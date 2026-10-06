//// zstd content coding for daemon HTTP bodies, on OTP 29's `zstd`. A
//// response is compressed when its request's Accept-Encoding admits zstd; a
//// request body may arrive compressed once the client has seen the
//// `zstd_requests` capability.

import gleam/bytes_tree.{type BytesTree}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/result
import gleam/string
import mist

/// Smaller bodies would not shrink by more than a frame header costs.
const minimum_bytes = 1024

@external(erlang, "albedo_http_api", "accepts_zstd")
fn accepts_zstd(header: String) -> Bool

@external(erlang, "albedo_http_api", "zstd_compress")
fn compress(data: BytesTree) -> BytesTree

/// A zstd request body, or Error unless it is one frame that declares a
/// decoded size of at most `limit` and decodes to exactly that.
@external(erlang, "albedo_http_api", "zstd_decompress")
pub fn decompress(data: BitArray, limit: Int) -> Result(BitArray, Nil)

/// Whether the request's Accept-Encoding admits zstd.
pub fn accepts(req: Request(a)) -> Bool {
  request.get_header(req, "accept-encoding")
  |> result.map(accepts_zstd)
  |> result.unwrap(False)
}

/// Compresses a JSON or text body of at least `minimum_bytes` when the request
/// accepts zstd. Validators describe the decoded representation either way.
pub fn encode(
  req: Request(a),
  reply: Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  let textual =
    response.get_header(reply, "content-type")
    |> result.map(fn(kind) {
      string.starts_with(kind, "application/json")
      || string.starts_with(kind, "application/problem+json")
      || string.starts_with(kind, "text/")
    })
    |> result.unwrap(False)
  case reply.body, textual {
    mist.Bytes(body), True -> {
      let reply = vary(reply)
      case
        bytes_tree.byte_size(body) >= minimum_bytes
        && response.get_header(reply, "content-encoding") == Error(Nil)
        && accepts(req)
      {
        True ->
          reply
          |> response.set_header("content-encoding", "zstd")
          |> response.set_body(mist.Bytes(compress(body)))
        False -> reply
      }
    }
    _, _ -> reply
  }
}

fn vary(reply: Response(a)) -> Response(a) {
  let value = case response.get_header(reply, "vary") {
    Ok(existing) -> existing <> ", Accept-Encoding"
    Error(_) -> "Accept-Encoding"
  }
  response.set_header(reply, "vary", value)
}

/// The coding of one event stream, owned by the process that writes it.
pub opaque type Stream {
  Identity
  Zstd(context: Context)
}

type Context

@external(erlang, "albedo_http_api", "zstd_stream")
fn context() -> Context

@external(erlang, "albedo_http_api", "zstd_flush")
fn flush(context: Context, data: BitArray) -> BytesTree

@external(erlang, "albedo_http_api", "zstd_end")
fn finish(context: Context) -> BytesTree

/// Starts a stream's coding. A zstd context works only in the process that
/// created it, so the stream process itself must call this.
pub fn start(coded: Bool) -> Stream {
  case coded {
    True -> Zstd(context())
    False -> Identity
  }
}

/// One chunk, flushed so the client can decode it without waiting.
pub fn chunk(coding: Stream, data: BitArray) -> BitArray {
  case coding {
    Identity -> data
    Zstd(context) -> bytes_tree.to_bit_array(flush(context, data))
  }
}

/// The bytes that close the stream's frame; identity has none.
pub fn close(coding: Stream) -> Result(BitArray, Nil) {
  case coding {
    Identity -> Error(Nil)
    Zstd(context) -> Ok(bytes_tree.to_bit_array(finish(context)))
  }
}
