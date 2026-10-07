//// Hard process death cannot execute callback cleanup; real socket ownership,
//// receive deadlines, and responses split at every byte require native
//// transport probes beyond daemon output.

import albedo/openai_api/transport
import gleam/bit_array
import gleam/list
import gleam/string_tree
import gleeunit/should

type Fixture

type Owner

type Mode {
  CloseDelimited
  ChunkedTrickle
  ContentLength
}

@external(erlang, "albedo_openai_transport_test_server", "start")
fn start(mode: Mode) -> Fixture

@external(erlang, "albedo_openai_transport_test_server", "url")
fn url(fixture: Fixture) -> String

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
  let assert Ok(#(transport.Headers(200, _, False), connection)) =
    transport.receive(connection)
  transport.receive(connection) |> should.equal(Error(transport.TimedOut))
  transport.close(connection)
  await_closed(idle) |> should.be_true
  stop(idle)
}

pub fn plain_http_bodies_end_where_their_framing_says_test() -> Nil {
  use mode <- list.each([ChunkedTrickle, ContentLength])
  let fixture = start(mode)
  let assert Ok(connection) =
    transport.open(url(fixture), [], string_tree.new(), 2000)
  let assert Ok(#(transport.Headers(200, _, False), connection)) =
    transport.receive(connection)
  body(connection, <<>>) |> should.equal(<<"hello world, all">>)
  transport.close(connection)
  stop(fixture)
}

fn body(connection: transport.Connection, read: BitArray) -> BitArray {
  let assert Ok(#(transport.Data(bytes, final), connection)) =
    transport.receive(connection)
  let read = bit_array.append(read, bytes)
  case final {
    True -> read
    False -> body(connection, read)
  }
}
