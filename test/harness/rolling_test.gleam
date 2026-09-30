//// Legacy cursor migration, chunked summaries, and image accounting are costly
//// or impossible to drive reliably through the shared E2E daemon.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extensions
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import sqlight

fn host(config: rolling.Config) {
  let installed = [rolling.configured_extension(config)]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, ["rolling"]),
    )
  let assert Ok(session) = runtime.open_session(host, "rolling-test", "/tmp")
  #(host, session)
}

fn long_history() {
  [
    types.User("u1 " <> string.repeat("a", 380)),
    types.Assistant("a1 " <> string.repeat("b", 380)),
    types.User("u2 " <> string.repeat("c", 380)),
    types.Assistant("a2 " <> string.repeat("d", 380)),
    types.User("u3 " <> string.repeat("e", 380)),
    types.Assistant("a3 " <> string.repeat("f", 380)),
  ]
}

/// A row saved before cuts counted user messages validates the old way, by
/// item count under its source, and is rewritten in the portable form.
pub fn legacy_item_count_state_upgrades_in_place_test() {
  let #(host, session) = host(rolling.Config(Some(10_000), 90, 25))
  let history = long_history()
  let assert Ok(_) =
    store.query(runtime.ledger(host), fn(db) {
      sqlight.query(
        "INSERT INTO rolling_compaction_state(session,summary,cutoff_count,source_hash) VALUES(?,?,?,?)",
        db,
        [
          sqlight.text("rolling-test"),
          sqlight.text("legacy facts"),
          sqlight.int(4),
          sqlight.text(
            compaction.fingerprint(#("model-a", list.take(history, 4))),
          ),
        ],
        decode.dynamic,
      )
    })
  let assert Ok([types.User(summary), _, ..tail]) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      fn(_) { Error("must not summarize") },
      history,
    )
  string.contains(summary, "legacy facts") |> should.be_true
  tail |> should.equal(list.drop(history, 4))
  let assert Ok([#(2, cut_hash)]) =
    store.query(runtime.ledger(host), fn(db) {
      sqlight.query(
        "SELECT cutoff_count,source_hash FROM rolling_compaction_state",
        db,
        [],
        {
          use users <- decode.field(0, decode.int)
          use hash <- decode.field(1, decode.string)
          decode.success(#(users, hash))
        },
      )
    })
  string.starts_with(cut_hash, "users:") |> should.be_true
  runtime.stop(host)
}

/// A long eviction folds into the summary chunk by chunk, each request under
/// half the window, carrying the summary forward.
pub fn long_eviction_summarizes_in_chunks_test() {
  let #(host, session) = host(rolling.Config(Some(2000), 90, 25))
  let history =
    list.flatten(list.repeat(long_history(), 4))
    |> list.index_map(fn(input, index) {
      case input {
        types.User(text) -> types.User(int.to_string(index) <> text)
        other -> other
      }
    })
  let requests = process.new_subject()
  let assert Ok(_) =
    runtime.compact_history_scoped(
      host,
      session,
      "model-a",
      "model-a",
      None,
      "",
      fn(request: compaction.SummaryRequest) {
        process.send(requests, request)
        Ok("after " <> int.to_string(list.length(request.evicted)))
      },
      history,
    )
  let assert Ok(compaction.SummaryRequest(_, None, first, _)) =
    process.receive(requests, 0)
  let assert Ok(compaction.SummaryRequest(_, Some(previous), _, _)) =
    process.receive(requests, 0)
  previous |> should.equal("after " <> int.to_string(list.length(first)))
  should.be_true(compaction.estimate_inputs(first) <= 1000)
  runtime.stop(host)
}

pub fn image_estimate_uses_dimensions_not_base64_transport_size_test() {
  let payload = string.repeat("A", 5 * 1024 * 1024)
  let assert Ok(image) =
    types.image("image/png", payload, 1024, 1024, 3 * 1024 * 1024)
  let input = types.UserImage("inspect", image)
  let transport_includes_payload =
    compaction.input_bytes(input) > 5 * 1024 * 1024
  transport_includes_payload |> should.equal(True)
  let estimate_excludes_payload = compaction.estimate_input(input) < 1000
  estimate_excludes_payload |> should.equal(True)
}
