import albedo/daemon/conversation
import albedo/daemon/session
import albedo/daemon/store
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import sqlight

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

fn info(id: String) -> conversation.Info {
  conversation.Info(
    id,
    "new session",
    "/tmp",
    "provider",
    "model",
    types.Responses,
    "idle",
    None,
  )
}

pub fn dormant_session_start_does_not_decode_full_transcript_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("dormant"))
  // An invalid durable payload makes an eager load fail. Starting must still
  // succeed because idle actors own metadata, not a full transcript cache.
  let assert Ok(_) =
    store.query(ledger, fn(db) {
      sqlight.exec(
        "INSERT INTO transcript(session,payload) VALUES('dormant',X'00')",
        db,
      )
    })
  let assert Ok(worker) = session.start(host, info("dormant"), "/tmp")
  let report = session.report(worker)
  report.history_loaded |> should.be_false
  report.running |> should.be_false
  session.status(worker) |> string.contains("resting") |> should.be_true
  session.close(worker)
  runtime.stop(host)
  cleanup(path)
}

pub fn evicted_idle_history_reloads_from_durable_transcript_test() {
  let path = temporary_database()
  let assert Ok(host) = runtime.start(path)
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) = conversation.create(ledger, info("reload"))
  let assert Ok(_) =
    conversation.commit(
      ledger,
      "reload",
      [types.User("first durable turn")],
      "idle",
    )
  let assert Ok(worker) = session.start(host, info("reload"), "/tmp")
  let first = session.read(worker, -1)
  list.any(first.events, string.contains(_, "first durable turn"))
  |> should.be_true
  session.report(worker).history_loaded |> should.be_true

  let assert Ok(_) =
    conversation.commit(
      ledger,
      "reload",
      [types.Assistant("written while detached")],
      "idle",
    )
  session.evict_history(worker) |> should.be_true
  session.report(worker).history_loaded |> should.be_false
  let reloaded = session.read(worker, -1)
  list.any(reloaded.events, string.contains(_, "written while detached"))
  |> should.be_true
  session.report(worker).history_loaded |> should.be_true

  session.close(worker)
  runtime.stop(host)
  cleanup(path)
}
