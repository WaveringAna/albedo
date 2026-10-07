//// Hard process death cannot execute callback cleanup; real socket ownership,
//// receive deadlines, responses split at every byte, connection reuse, and
//// certificate verification require native transport probes beyond daemon
//// output.

import albedo/openai_api/transport
import gleam/bit_array
import gleam/erlang/process
import gleam/list
import gleam/string
import gleam/string_tree
import gleeunit/should

type Fixture

type Owner

type Mode {
  CloseDelimited
  ChunkedTrickle
  ContentLength
  KeepAlive
  DropSecond
  SlowEnd
}

@external(erlang, "albedo_openai_transport_test_server", "start")
fn start(mode: Mode) -> Fixture

@external(erlang, "albedo_openai_transport_test_server", "start_tls")
fn start_tls(mode: Mode) -> Fixture

@external(erlang, "albedo_openai_transport_test_server", "url")
fn url(fixture: Fixture) -> String

@external(erlang, "albedo_openai_transport_test_server", "trust")
fn trust(fixture: Fixture) -> Nil

@external(erlang, "albedo_openai_transport_test_server", "distrust")
fn distrust() -> Nil

@external(erlang, "albedo_openai_transport_test_server", "owner_after_headers")
fn owner_after_headers(fixture: Fixture) -> Owner

@external(erlang, "albedo_openai_transport_test_server", "kill_owner")
fn kill_owner(owner: Owner) -> Bool

@external(erlang, "albedo_openai_transport_test_server", "await_closed")
fn await_closed(fixture: Fixture) -> Bool

@external(erlang, "albedo_openai_transport_test_server", "stop")
fn stop(fixture: Fixture) -> Nil

pub fn close_delimited_transport_releases_owned_sockets_test() -> Nil {
  let killed = start(CloseDelimited)
  let owner = owner_after_headers(killed)
  kill_owner(owner) |> should.be_true
  await_closed(killed) |> should.be_true
  stop(killed)

  let idle = start(CloseDelimited)
  let assert Ok(connection) =
    transport.open(url(idle), [], string_tree.new(), 2000)
  let assert Ok(transport.Headers(200, _, False)) =
    transport.receive(connection)
  transport.receive(connection) |> should.equal(Error(transport.TimedOut))
  transport.close(connection)
  await_closed(idle) |> should.be_true
  stop(idle)
}

pub fn plain_http_bodies_end_where_their_framing_says_test() -> Nil {
  use mode <- list.each([ChunkedTrickle, ContentLength])
  let fixture = start(mode)
  get(url(fixture)) |> should.equal(Ok(<<"hello world, all">>))
  stop(fixture)
}

/// The fixture closes its listener after one connection, so the second
/// request succeeds only on the connection the first one left open.
pub fn a_finished_response_leaves_its_connection_for_the_next_request_test() -> Nil {
  let fixture = start(KeepAlive)
  get(url(fixture)) |> should.equal(Ok(<<"hello world, all">>))
  get(url(fixture)) |> should.equal(Ok(<<"hello world, all">>))
  stop(fixture)
}

pub fn a_kept_connection_the_server_dropped_is_replaced_test() -> Nil {
  let fixture = start(DropSecond)
  get(url(fixture)) |> should.equal(Ok(<<"hello world, all">>))
  get(url(fixture)) |> should.equal(Ok(<<"hello world, all">>))
  stop(fixture)
}

/// A stream that has its last event returns before the chunked terminator,
/// which the fixture sends 50 ms later; once it has arrived, the connection
/// serves the next request.
pub fn a_finished_exchange_keeps_its_connection_before_the_response_ends_test() -> Nil {
  let fixture = start(SlowEnd)
  first_chunk(url(fixture), Ok) |> should.equal(Ok(<<"hello world, all">>))
  process.sleep(100)
  first_chunk(url(fixture), Ok) |> should.equal(Ok(<<"hello world, all">>))
  stop(fixture)
}

pub fn a_failed_exchange_closes_its_connection_test() -> Nil {
  let fixture = start(SlowEnd)
  first_chunk(url(fixture), fn(_) { Error(Nil) }) |> should.equal(Error(Nil))
  await_closed(fixture) |> should.be_true
  stop(fixture)
}

pub fn https_verifies_the_server_certificate_test() -> Nil {
  let untrusted = start_tls(KeepAlive)
  let assert Error(transport.TransportError(reason)) =
    transport.open(url(untrusted), [], string_tree.new(), 2000)
  string.contains(reason, "Unknown CA") |> should.be_true
  stop(untrusted)

  let trusted = start_tls(KeepAlive)
  trust(trusted)
  let first = get(url(trusted))
  let second = get(url(trusted))
  distrust()
  stop(trusted)
  first |> should.equal(Ok(<<"hello world, all">>))
  second |> should.equal(Ok(<<"hello world, all">>))
}

/// One request read to its end and closed.
fn get(url: String) -> Result(BitArray, transport.Error) {
  let assert Ok(connection) = transport.open(url, [], string_tree.new(), 2000)
  let read = {
    let assert Ok(transport.Headers(200, _, False)) =
      transport.receive(connection)
    body(connection, <<>>)
  }
  transport.close(connection)
  read
}

/// One request whose exchange ends after the first body chunk, as `finish`
/// says.
fn first_chunk(
  url: String,
  finish: fn(BitArray) -> Result(BitArray, Nil),
) -> Result(BitArray, Nil) {
  let assert Ok(connection) = transport.open(url, [], string_tree.new(), 2000)
  use <- transport.with_connection(connection)
  let assert Ok(transport.Headers(200, _, False)) =
    transport.receive(connection)
  let assert Ok(transport.Data(bytes, False)) = transport.receive(connection)
  finish(bytes)
}

fn body(
  connection: transport.Connection,
  read: BitArray,
) -> Result(BitArray, transport.Error) {
  case transport.receive(connection) {
    Ok(transport.Data(bytes, True)) -> Ok(bit_array.append(read, bytes))
    Ok(transport.Data(bytes, False)) ->
      body(connection, bit_array.append(read, bytes))
    Ok(transport.Headers(..)) ->
      Error(transport.TransportError("headers again"))
    Error(error) -> Error(error)
  }
}
