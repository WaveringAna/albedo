import albedo/openai_api/transport
import gleam/bit_array
import gleam/string_tree
import gleeunit/should

type Fixture

type Mode {
  Stream
  Disconnect
  Hold
}

@external(erlang, "albedo_openai_transport_test_server", "start")
fn start(mode: Mode) -> Fixture

@external(erlang, "albedo_openai_transport_test_server", "url")
fn url(fixture: Fixture) -> String

@external(erlang, "albedo_openai_transport_test_server", "await_body")
fn await_body(fixture: Fixture) -> BitArray

@external(erlang, "albedo_openai_transport_test_server", "await_closed")
fn await_closed(fixture: Fixture) -> Bool

@external(erlang, "albedo_openai_transport_test_server", "stop")
fn stop(fixture: Fixture) -> Nil

@external(erlang, "albedo_openai_transport_test_server", "raising_callback_closes")
fn raising_callback_closes(connection: transport.Connection) -> Bool

fn open_fixture(fixture: Fixture, body: string_tree.StringTree) {
  transport.open(url(fixture), [], body, 1000)
  |> should.be_ok
}

fn read_body(connection: transport.Connection, bytes: BitArray) {
  case transport.receive(connection) |> should.be_ok {
    transport.Headers(_, _, _) -> read_body(connection, bytes)
    transport.Data(chunk, True) -> bit_array.append(bytes, chunk)
    transport.Data(chunk, False) ->
      read_body(connection, bit_array.append(bytes, chunk))
  }
}

pub fn streams_request_and_response_body_test() {
  let fixture = start(Stream)
  let request = string_tree.from_strings(["hello", " ", "world"])
  let connection = open_fixture(fixture, request)

  let assert transport.Headers(200, _, False) =
    transport.receive(connection) |> should.be_ok
  let response = read_body(connection, <<>>)

  assert await_body(fixture) == <<"hello world":utf8>>
  assert response == <<"onetwo":utf8>>
  transport.close(connection)
  stop(fixture)
}

pub fn early_disconnect_is_transport_error_test() {
  let fixture = start(Disconnect)
  let connection = open_fixture(fixture, string_tree.new())

  let assert Error(transport.TransportError(_)) = transport.receive(connection)
  transport.close(connection)
  stop(fixture)
}

pub fn receive_timeout_is_finite_test() {
  let fixture = start(Hold)
  let connection =
    transport.open(url(fixture), [], string_tree.new(), 100)
    |> should.be_ok

  let assert transport.Headers(200, _, False) =
    transport.receive(connection) |> should.be_ok
  let assert Error(transport.TimedOut) = transport.receive(connection)

  transport.close(connection)
  assert await_closed(fixture)
  stop(fixture)
}

pub fn with_connection_closes_when_callback_raises_test() {
  let fixture = start(Hold)
  let connection = open_fixture(fixture, string_tree.new())

  assert raising_callback_closes(connection)
  assert await_closed(fixture)
  stop(fixture)
}

pub fn rejects_invalid_urls_and_timeouts_test() {
  let body = string_tree.new()
  let assert Error(transport.InvalidUrl) =
    transport.open("ftp://example.com/path", [], body, 100)
  let assert Error(transport.InvalidUrl) =
    transport.open("https://user:secret@example.com/path", [], body, 100)
  let assert Error(transport.InvalidUrl) =
    transport.open("https://example.com/path#fragment", [], body, 100)
  let assert Error(transport.InvalidUrl) =
    transport.open("https://example.com/path", [], body, 0)
}
