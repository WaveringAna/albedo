//// Building a request must not change what the next one builds: every
//// strategy's projection reads its saved state and writes nothing, even when
//// the history no longer matches that state. Only a compaction writes. The
//// E2E harness cannot run a projection apart from the compaction that may
//// follow it, so it cannot tell a read from a write.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/memory
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import harness/session_fixture
import sqlight

pub fn rolling_projection_writes_nothing_test() -> Nil {
  projections_write_nothing(
    [rolling.configured_extension(rolling.Config(Some(100_000), 90, 25))],
    ["rolling"],
  )
}

pub fn lcm_projection_writes_nothing_test() -> Nil {
  projections_write_nothing(
    [
      memory.extension(),
      lcm.configured_extension(lcm.Config(Some(100_000), 90, 25)),
    ],
    ["lcm-memory", "lcm"],
  )
}

pub fn snapcompact_projection_writes_nothing_test() -> Nil {
  projections_write_nothing([snapcompact.memory(), snapcompact.extension()], [
    "snapcompact-memory",
    "snapcompact",
  ])
}

/// Compacts once, then prepares requests below the trigger: from the history
/// the compaction saw, and from a rewritten one its saved state no longer
/// matches. Neither may write.
fn projections_write_nothing(
  installed: List(extension.Extension),
  enabled: List(String),
) -> Nil {
  let assert Ok(host) =
    runtime.start_with_config(":memory:", extensions.Config(installed, enabled))
  session_fixture.initialise(host)
  session_fixture.create(host, "projection", "/tmp")
  let ledger = runtime.ledger(host)
  let history = conversation_of(["first", "second", "third", "fourth"])
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "projection",
      history,
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok(session) = runtime.open_session(host, "projection", "/tmp")
  let assert Ok(_) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "model",
      None,
      "",
      fn(_) { Ok("summary of earlier work") },
      history,
    )
  let prepare = fn(history) {
    let before = changes(ledger)
    let assert Ok(inputs) =
      runtime.prepare_history_with(
        host,
        session,
        "model",
        "",
        fn(_) { Error("a projection must not summarize") },
        history,
      )
    changes(ledger) |> should.equal(before)
    inputs
  }
  // The saved compaction stands in for the start of the history it covers.
  prepare(history) |> should.not_equal(history)
  prepare(conversation_of(["rewritten", "second", "third", "fourth"]))
  runtime.stop(host)
}

fn conversation_of(topics: List(String)) -> List(types.Input) {
  list.flat_map(topics, fn(topic) {
    [
      types.User(topic <> " " <> string.repeat("q", 4000)),
      types.Assistant(topic <> " answer " <> string.repeat("a", 4000)),
    ]
  })
}

/// Rows the store's one connection has changed since it opened.
fn changes(ledger: store.Store) -> Int {
  let assert Ok([count]) =
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT total_changes()",
        db,
        [],
        decode.field(0, decode.int, decode.success),
      )
    })
  count
}
