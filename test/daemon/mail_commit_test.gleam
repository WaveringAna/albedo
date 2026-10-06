/// E2E cannot pause admission just before its transaction; this catches close winning that race.
import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/mail
import albedo/daemon/store
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleeunit/should

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

pub fn close_before_mail_commit_rolls_back_turn_and_preserves_letter_test() -> Nil {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = family.initialise(ledger)
  let assert Ok(_) = mail.initialise(ledger)
  let parent =
    conversation.Info(
      "parent",
      "parent",
      "/tmp",
      "provider",
      "model",
      types.Responses,
      conversation.Idle,
      None,
      None,
    )
  let assert Ok(_) = conversation.create(ledger, parent)
  let assert Ok(_) =
    conversation.create(ledger, conversation.Info(..parent, id: "child"))
  let assert Ok(_) =
    store.query(ledger, fn(connection) {
      family.link_in(connection, "child", "parent", "child")
    })
  let assert Ok(_) =
    mail.post(
      ledger,
      "closed-letter",
      "child",
      Some("parent"),
      "parent",
      mail.Task,
      "task",
    )
  let assert Ok(open_letter) =
    mail.post(
      ledger,
      "open-letter",
      "parent",
      None,
      "outside",
      mail.Message,
      "open",
    )
  let assert Ok(_) = family.close(ledger, "child")

  // This is the commit an already-admitted letter would attempt after close.
  conversation.commit_operations(
    ledger,
    "child",
    [types.User("task")],
    conversation.Model,
    None,
    ["closed-letter"],
    [],
    "turn",
    "/tmp",
  )
  |> should.equal(Error("session is closed"))
  conversation.load(ledger, "child") |> should.equal(Ok([]))
  mail.undelivered(ledger, "closed-letter") |> should.be_true
  store.read(
    ledger,
    "SELECT count(*) FROM input_turns",
    [],
    decode.field(0, decode.int, decode.success),
  )
  |> should.equal(Ok([0]))
  // Closed recipients must be excluded before the dispatcher's limit.
  mail.pending(ledger, 1) |> should.equal(Ok([open_letter]))

  // The closed family flag does not prohibit manual chat with no letters.
  conversation.commit(
    ledger,
    "child",
    [types.User("manual")],
    conversation.Idle,
  )
  |> should.be_ok
  mail.undelivered(ledger, "closed-letter") |> should.be_true
  runtime.stop(host)
  cleanup(path)
}
