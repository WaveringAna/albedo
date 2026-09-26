import albedo/daemon/conversation
import albedo/daemon/image
import albedo/daemon/images
import albedo/daemon/store
import albedo/harness/runtime
import albedo/openai_api
import albedo/openai_api/request
import albedo/openai_api/transport
import albedo/openai_api/types
import gleam/bit_array
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None}
import gleam/string_tree
import gleeunit/should
import sqlight

const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

@external(erlang, "albedo_image_store_test_support", "legacy_payload")
fn legacy_payload(text: String, data: String) -> BitArray

@external(erlang, "albedo_image_store_test_support", "exists")
fn exists(path: String) -> Bool

@external(erlang, "albedo_image_store_test_support", "legacy_fingerprint")
fn old_fingerprint(source: String, text: String, data: String) -> String

@external(erlang, "albedo_compaction", "fingerprint")
fn fingerprint(value: a) -> String

@external(erlang, "albedo_rolling", "legacy_fingerprint")
fn legacy_fingerprint(value: a) -> Result(String, Nil)

type Fixture

type Mode {
  Stream
}

@external(erlang, "albedo_openai_transport_test_server", "start")
fn start_server(mode: Mode) -> Fixture

@external(erlang, "albedo_openai_transport_test_server", "url")
fn url(fixture: Fixture) -> String

@external(erlang, "albedo_openai_transport_test_server", "await_body")
fn await_body(fixture: Fixture) -> BitArray

@external(erlang, "albedo_openai_transport_test_server", "stop")
fn stop(fixture: Fixture) -> Nil

fn test_image() -> types.Image {
  let assert Ok(value) = image.validate("image/png", png, 2, 3, 24)
  value
}

fn session(id: String) -> conversation.Info {
  conversation.Info(
    id,
    "new session",
    "/tmp",
    "provider",
    "model",
    types.Responses,
    conversation.Idle,
    None,
    None,
  )
}

fn ledger() -> #(String, store.Store) {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  #(path, ledger)
}

fn count(ledger: store.Store, sql: String) -> Int {
  let assert Ok([n]) =
    store.query(ledger, fn(db) {
      sqlight.query(sql, db, [], decode.field(0, decode.int, decode.success))
    })
  n
}

fn inputs() -> List(types.Input) {
  [
    types.UserImage("look", test_image()),
    types.ToolOutput("call", "rendered", [test_image(), test_image()]),
  ]
}

fn loaded(ledger: store.Store, id: String) -> List(types.Input) {
  let assert Ok(entries) = conversation.load_entries(ledger, id)
  list.map(entries, fn(entry) { entry.input })
}

pub fn commit_keeps_one_payload_and_rows_load_references_test() {
  let #(path, ledger) = ledger()
  let assert Ok(_) = conversation.create(ledger, session("s"))
  let assert Ok(_) =
    conversation.commit(ledger, "s", inputs(), conversation.Idle)

  count(ledger, "SELECT count(*) FROM images") |> should.equal(1)
  count(
    ledger,
    "SELECT count(*) FROM transcript WHERE instr(payload,CAST('"
      <> png
      <> "' AS BLOB))>0",
  )
  |> should.equal(0)

  let assert [types.UserImage("look", first), types.ToolOutput(_, _, [_, _])] =
    loaded(ledger, "s")
  let assert types.StoredData(_, size, read) = types.image_data(first)
  size |> should.equal(24 + 8)
  read() |> should.equal(Ok(png))
  types.image_meta(first) |> should.equal(#("image/png", 2, 3, 24))
  cleanup(path)
}

pub fn stored_images_stream_the_same_request_bytes_test() {
  let #(path, ledger) = ledger()
  let assert Ok(_) = conversation.create(ledger, session("s"))
  let assert Ok(_) =
    conversation.commit(ledger, "s", inputs(), conversation.Idle)
  let assert Ok(inline) =
    request.encode(types.Responses, openai_api.request("m", inputs()))
  let assert Ok(stored) =
    request.encode(
      types.Responses,
      openai_api.request("m", loaded(ledger, "s")),
    )

  let fixture = start_server(Stream)
  let assert Ok(connection) = transport.open(url(fixture), [], stored, 1000)
  let body = await_body(fixture)
  transport.close(connection)
  stop(fixture)

  body |> should.equal(bit_array.from_string(string_tree.to_string(inline)))
  cleanup(path)
}

pub fn a_missing_payload_fails_the_request_test() {
  let #(path, ledger) = ledger()
  let assert Ok(_) = conversation.create(ledger, session("s"))
  let assert Ok(_) =
    conversation.commit(ledger, "s", inputs(), conversation.Idle)
  let assert Ok(body) =
    request.encode(
      types.Responses,
      openai_api.request("m", loaded(ledger, "s")),
    )
  let assert Ok(_) =
    store.query(ledger, fn(db) { sqlight.exec("DELETE FROM images", db) })

  let fixture = start_server(Stream)
  let assert Error(transport.TransportError(_)) =
    transport.open(url(fixture), [], body, 1000)
  stop(fixture)
  cleanup(path)
}

pub fn deleting_a_session_releases_only_unshared_payloads_test() {
  let #(path, ledger) = ledger()
  let assert Ok(_) = conversation.create(ledger, session("a"))
  let assert Ok(_) = conversation.create(ledger, session("b"))
  let assert Ok(_) =
    conversation.commit(ledger, "a", inputs(), conversation.Idle)
  let assert Ok(_) =
    conversation.commit(ledger, "b", inputs(), conversation.Idle)

  let assert Ok(_) = conversation.delete(ledger, "a")
  count(ledger, "SELECT count(*) FROM images") |> should.equal(1)
  let assert [types.UserImage(_, kept), ..] = loaded(ledger, "b")
  let assert types.StoredData(read: read, ..) = types.image_data(kept)
  read() |> should.equal(Ok(png))

  let assert Ok(_) = conversation.delete(ledger, "b")
  count(ledger, "SELECT count(*) FROM images") |> should.equal(0)
  cleanup(path)
}

pub fn migration_moves_legacy_payloads_once_after_a_backup_test() {
  let #(path, ledger) = ledger()
  let assert Ok(_) = conversation.create(ledger, session("s"))
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "INSERT INTO transcript(session,payload) VALUES('s',?)",
        db,
        [sqlight.blob(legacy_payload("old", png))],
        decode.dynamic,
      )
    })
  let assert [types.UserImage("old", before)] = loaded(ledger, "s")
  types.image_data(before) |> should.equal(types.InlineData(png))

  let backup = path <> ".backup/before.sqlite"
  images.migrate(ledger, backup) |> should.equal(Ok(1))
  exists(backup) |> should.be_true
  let assert [types.UserImage("old", after)] = loaded(ledger, "s")
  let assert types.StoredData(read: read, ..) = types.image_data(after)
  read() |> should.equal(Ok(png))
  images.migrate(ledger, backup) |> should.equal(Ok(0))
  cleanup(path)
}

pub fn fingerprints_ignore_where_a_payload_lives_test() {
  let #(path, ledger) = ledger()
  let assert Ok(_) = conversation.create(ledger, session("s"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "s",
      [types.UserImage("look", test_image())],
      conversation.Idle,
    )
  let stored = loaded(ledger, "s")
  let inline = [types.UserImage("look", test_image())]

  fingerprint(#("source", stored))
  |> should.equal(fingerprint(#("source", inline)))
  legacy_fingerprint(#("source", stored))
  |> should.equal(Ok(old_fingerprint("source", "look", png)))
  // Without images the current fingerprint is the one saved before.
  fingerprint(#("source", [types.User("hi")]))
  |> should.equal(fingerprint(#("source", [types.User("hi")])))
  cleanup(path)
}
