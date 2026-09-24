import albedo/daemon/conversation
import albedo/daemon/events
import albedo/daemon/history
import albedo/daemon/image
import albedo/daemon/store
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import sqlight

const png = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD"

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

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

pub fn validation_uses_canonical_bytes_header_and_derived_metadata_test() {
  let value = test_image()
  types.image_parts(value) |> should.equal(#("image/png", png, 2, 3, 24))
  image.validate("image/jpeg", png, 2, 3, 24)
  |> should.equal(Error("image metadata does not match its payload"))
  image.validate("image/png", png, 2, 4, 24)
  |> should.equal(Error("image metadata does not match its payload"))
  image.validate("image/png", "aGVsbG8=", 2, 3, 5)
  |> should.equal(Error("invalid image payload or header"))
  image.validate("image/png", "iVBORw0KGgoAAAANSUhEUgAAAAIAAAAD=", 2, 3, 24)
  |> should.equal(Error("invalid image payload or header"))
}

pub fn user_events_expose_metadata_without_the_base64_payload_test() {
  let event =
    events.user_image(
      "describe",
      "chat",
      Some("client"),
      Some(42),
      test_image(),
    )
  let image_decoder = {
    use mime <- decode.field("mimeType", decode.string)
    use width <- decode.field("width", decode.int)
    use height <- decode.field("height", decode.int)
    use bytes <- decode.field("bytes", decode.int)
    use payload <- decode.optional_field(
      "data",
      None,
      decode.optional(decode.string),
    )
    decode.success(#(mime, width, height, bytes, payload))
  }
  let decoder = decode.field("image", image_decoder, decode.success)
  json.parse(event, decoder)
  |> should.equal(Ok(#("image/png", 2, 3, 24, None)))
}

pub fn image_inputs_survive_restart_and_fork_without_losing_payload_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, session("source"))
  let input = types.UserImage("describe", test_image())
  let assert Ok(_) =
    conversation.commit(ledger, "source", [input], conversation.Idle)
  let assert Ok([checkpoint]) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT seq FROM transcript WHERE session='source'",
        db,
        [],
        decode.field(0, decode.int, decode.success),
      )
    })
  let assert Ok(_) = history.fork(ledger, "source", "branch", checkpoint)
  conversation.load(ledger, "source") |> should.equal(Ok([input]))
  conversation.load(ledger, "branch") |> should.equal(Ok([input]))
  runtime.stop(host)

  let assert Ok(restarted) = runtime.start(path)
  let ledger = runtime.ledger(restarted)
  let assert Ok(_) = conversation.initialise(ledger)
  conversation.load(ledger, "source") |> should.equal(Ok([input]))
  conversation.load(ledger, "branch") |> should.equal(Ok([input]))
  runtime.stop(restarted)
  cleanup(path)
}
