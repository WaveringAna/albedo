import gleam/string_tree.{type StringTree}

/// A streaming HTTP connection owned by the process that opened it.
pub type Connection

pub type Error {
  InvalidUrl
  TransportError(String)
  TimedOut
}

pub type Message {
  Headers(status: Int, headers: List(#(String, String)), final: Bool)
  Data(bytes: BitArray, final: Bool)
}

/// Open a POST request and begin its streaming response.
@external(erlang, "albedo_openai_transport", "open")
pub fn open(
  url: String,
  headers: List(#(String, String)),
  body: StringTree,
  timeout_ms: Int,
) -> Result(Connection, Error)

/// Wait for the next response headers or body chunk.
@external(erlang, "albedo_openai_transport", "receive_message")
pub fn receive(connection: Connection) -> Result(Message, Error)

/// Close the connection, or keep it for the next request to the same host
/// when its whole response was read, and discard its pending messages.
@external(erlang, "albedo_openai_transport", "close")
pub fn close(connection: Connection) -> Nil

/// Run a callback and close the connection whether it returns or raises. A
/// callback that returns Ok keeps the connection for the next request even
/// when the response's last bytes have not been read yet.
@external(erlang, "albedo_openai_transport", "with_connection")
pub fn with_connection(connection: Connection, run: fn() -> value) -> value
