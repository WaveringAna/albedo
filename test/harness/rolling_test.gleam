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

@external(erlang, "albedo_runtime_test_support", "temporary_database")
fn temporary_database() -> String

@external(erlang, "albedo_runtime_test_support", "cleanup")
fn cleanup(path: String) -> Nil

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

fn summarize(text: String) {
  fn(_: compaction.SummaryRequest) { Ok(text) }
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

pub fn manual_compaction_uses_active_strategy_below_trigger_test() {
  let #(host, session) = host(rolling.Config(Some(10_000), 90, 25))
  let history = long_history()
  let summaries = process.new_subject()
  let assert Ok(projected) =
    runtime.compact_history_scoped(
      host,
      session,
      "model-a",
      "model-a",
      "",
      "system",
      fn(request) {
        process.send(summaries, request)
        Ok("kept facts")
      },
      history,
    )
  let assert Ok(compaction.SummaryRequest(_, None, evicted, _)) =
    process.receive(summaries, 0)
  list.is_empty(evicted) |> should.be_false
  let assert [types.User(summary), types.User(_), ..tail] = projected
  string.contains(summary, "kept facts") |> should.be_true
  tail |> should.equal(list.drop(history, list.length(evicted)))
  let assert Ok(Some(observation)) =
    rolling.observation(runtime.ledger(host), "rolling-test")
  observation.status |> should.equal("compacted")
  // A normal next request reuses the saved projection without summarizing again.
  runtime.prepare_history_with(
    host,
    session,
    "model-a",
    "system",
    fn(_) { Error("unexpected summary") },
    history,
  )
  |> should.equal(Ok(projected))
  runtime.stop(host)
}

pub fn manual_compaction_works_without_known_model_capacity_test() {
  let #(host, session) = host(rolling.Config(None, 90, 25))
  let history = long_history()
  let assert Ok(projected) =
    runtime.compact_history_scoped(
      host,
      session,
      "model-a",
      "model-a",
      "",
      "system",
      summarize("manual facts"),
      history,
    )
  let assert [types.User(summary), ..] = projected
  string.contains(summary, "manual facts") |> should.be_true
  // The saved projection outlives the manual run: the next ordinary request
  // uses it even though no context window is known, and grows its tail.
  let grown =
    list.append(history, [types.User("newer"), types.Assistant("reply")])
  let assert Ok(reused) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "system",
      fn(_) { Error("must not summarize again") },
      grown,
    )
  let assert [types.User(kept), types.User(_recap), ..reused_tail] = reused
  string.contains(kept, "manual facts") |> should.be_true
  reused_tail |> should.equal(list.drop(grown, 4))
  let assert Ok(Some(observation)) =
    rolling.observation(runtime.ledger(host), "rolling-test")
  observation.status |> should.equal("compacted")
  runtime.stop(host)
}

pub fn below_threshold_is_an_exact_no_op_test() {
  let #(host, session) = host(rolling.Config(Some(10_000), 90, 25))
  let history = [types.User("hello"), types.Assistant("hi")]
  runtime.prepare_history_with(
    host,
    session,
    "model-a",
    "system",
    fn(_) { Error("must not summarize") },
    history,
  )
  |> should.equal(Ok(history))
  let assert Ok(Some(observation)) =
    rolling.observation(runtime.ledger(host), "rolling-test")
  observation.status |> should.equal("not_needed")
  observation.source
  |> string.contains("estimated")
  |> should.be_true
  runtime.stop(host)
}

pub fn trigger_projects_summary_then_recap_then_whole_tail_test() {
  let #(host, session) = host(rolling.Config(Some(700), 90, 25))
  let history = long_history()
  let assert Ok(projected) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "system",
      summarize("older facts"),
      history,
    )
  let assert [types.User(summary), types.User(recap), ..tail] = projected
  string.starts_with(summary, "[older conversation summary")
  |> should.be_true
  string.contains(summary, "older facts") |> should.be_true
  string.starts_with(recap, "[recent user excerpts") |> should.be_true
  tail |> should.equal(list.drop(history, 4))
  let assert Ok(Some(observation)) =
    rolling.observation(runtime.ledger(host), "rolling-test")
  observation.status |> should.equal("compacted")
  observation.summary_items |> should.equal(1)
  observation.recap_items |> should.equal(1)
  observation.tail_items |> should.equal(2)
  // Reusing a valid cursor does not call the summarizer again.
  runtime.prepare_history_with(
    host,
    session,
    "model-a",
    "system",
    fn(_) { Error("must not summarize again") },
    history,
  )
  |> should.equal(Ok(projected))
  runtime.stop(host)
}

pub fn tool_output_stays_with_its_assistant_unit_test() {
  let #(host, session) = host(rolling.Config(Some(650), 40, 20))
  let history = [
    types.User("old " <> string.repeat("a", 500)),
    types.Assistant("tool call representation"),
    types.ToolOutput("call-1", string.repeat("x", 300), []),
    types.User("new"),
    types.Assistant("answer"),
  ]
  let assert Ok(projected) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      summarize("summarized tool turn"),
      history,
    )
  let assert [types.User(_), types.User(_), ..tail] = projected
  tail |> should.equal([types.User("new"), types.Assistant("answer")])
  runtime.stop(host)
}

/// The cut counts user messages, which every provider projection keeps, so
/// a text summary made before a model switch still applies after it.
pub fn summary_survives_a_model_or_provider_change_test() {
  let #(host, session) = host(rolling.Config(Some(700), 90, 25))
  let history = long_history()
  let assert Ok(first) =
    runtime.prepare_history_scoped(
      host,
      session,
      "model-a",
      "provider-a:model-a",
      "",
      "",
      summarize("first"),
      history,
    )
  // The new provider projects assistant output differently.
  let projected =
    list.map(history, fn(input) {
      case input {
        types.Assistant(text) -> types.Assistant(string.slice(text, 0, 20))
        other -> other
      }
    })
  let assert Ok(second) =
    runtime.prepare_history_scoped(
      host,
      session,
      "model-b",
      "provider-b:model-b",
      "",
      "",
      fn(_) { Error("must not summarize again") },
      projected,
    )
  list.take(second, 1) |> should.equal(list.take(first, 1))
  list.drop(second, 2) |> should.equal(list.drop(projected, 4))
  runtime.stop(host)
}

pub fn rewritten_history_resets_the_summary_test() {
  let #(host, session) = host(rolling.Config(Some(700), 90, 25))
  let history = long_history()
  let assert Ok(_) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      summarize("first"),
      history,
    )
  let rewritten = [
    types.User("u1 rewritten " <> string.repeat("z", 380)),
    ..list.drop(history, 1)
  ]
  let requests = process.new_subject()
  let assert Ok(_) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      fn(request) {
        process.send(requests, request)
        Ok("second")
      },
      rewritten,
    )
  let assert Ok(compaction.SummaryRequest(_, None, _, _)) =
    process.receive(requests, 0)
  runtime.stop(host)
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
      "",
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

pub fn summarizer_failure_keeps_previous_state_usable_test() {
  let #(host, session) = host(rolling.Config(Some(700), 90, 25))
  let history = long_history()
  let assert Ok(saved_projection) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      summarize("saved"),
      history,
    )
  let extended =
    list.append(history, [
      types.User("u4 " <> string.repeat("g", 380)),
      types.Assistant("a4 " <> string.repeat("h", 380)),
      types.User("u5 " <> string.repeat("i", 380)),
      types.Assistant("a5 " <> string.repeat("j", 380)),
    ])

  runtime.prepare_history_with(
    host,
    session,
    "model-a",
    "",
    fn(_) { Error("provider unavailable") },
    extended,
  )
  |> should.equal(Error("compaction rolling: provider unavailable"))
  runtime.prepare_history_with(
    host,
    session,
    "model-a",
    "",
    fn(_) { Error("must retain the saved projection") },
    history,
  )
  |> should.equal(Ok(saved_projection))

  let requests = process.new_subject()
  let assert Ok(_) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      fn(request) {
        process.send(requests, request)
        Ok("recovered")
      },
      extended,
    )
  let assert Ok(compaction.SummaryRequest(_, Some("saved"), _, _)) =
    process.receive(requests, 0)
  runtime.stop(host)
}

pub fn unknown_capacity_is_observable_and_never_summarizes_test() {
  let #(host, session) = host(rolling.Config(None, 90, 25))
  let history = long_history()
  runtime.prepare_history_with(
    host,
    session,
    "model-a",
    "",
    fn(_) { Error("must not summarize") },
    history,
  )
  |> should.equal(Ok(history))
  let assert Ok(Some(observation)) =
    rolling.observation(runtime.ledger(host), "rolling-test")
  observation.status |> should.equal("unknown")
  observation.capacity_tokens |> should.equal(None)
  runtime.stop(host)
}

pub fn pinned_overhead_reports_limitation_test() {
  let #(host, session) = host(rolling.Config(Some(100), 90, 25))
  let assert Error(error) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      string.repeat("system", 100),
      fn(_) { Error("must not summarize") },
      [types.User("hello")],
    )
  string.contains(error, "pinned system") |> should.be_true
  let assert Ok(Some(observation)) =
    rolling.observation(runtime.ledger(host), "rolling-test")
  observation.status |> should.equal("limitation")
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

pub fn image_recap_omits_binary_but_tail_preserves_image_test() {
  let assert Ok(image) =
    types.image("image/png", string.repeat("A", 400), 10, 10, 300)
  let #(host, session) = host(rolling.Config(Some(350), 65, 30))
  let history = [
    types.UserImage("inspect this", image),
    types.Assistant(string.repeat("old", 200)),
    types.User("latest"),
    types.Assistant("done"),
  ]
  let assert Ok([types.User(_), types.User(recap), ..tail]) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      summarize("image facts"),
      history,
    )
  string.contains(recap, "[image omitted from recap]") |> should.be_true
  string.contains(recap, string.repeat("A", 100)) |> should.be_false
  tail |> should.equal([types.User("latest"), types.Assistant("done")])
  runtime.stop(host)
}

pub fn later_trigger_folds_previous_summary_and_only_newly_evicted_test() {
  let #(host, session) = host(rolling.Config(Some(700), 90, 25))
  let history = long_history()
  let assert Ok(_) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      summarize("first"),
      history,
    )
  let extended =
    list.append(history, [
      types.User("u4 " <> string.repeat("g", 380)),
      types.Assistant("a4 " <> string.repeat("h", 380)),
      types.User("u5 " <> string.repeat("i", 380)),
      types.Assistant("a5 " <> string.repeat("j", 380)),
    ])
  let requests = process.new_subject()
  let assert Ok(_) =
    runtime.prepare_history_with(
      host,
      session,
      "model-a",
      "",
      fn(request) {
        process.send(requests, request)
        Ok("second")
      },
      extended,
    )
  let assert Ok(compaction.SummaryRequest(_, Some("first"), evicted, _)) =
    process.receive(requests, 0)
  evicted |> should.equal(list.take(list.drop(extended, 4), 4))
  runtime.stop(host)
}

pub fn rolling_state_survives_restart_when_projection_prefix_matches_test() {
  let path = temporary_database()
  let config = rolling.Config(Some(700), 90, 25)
  let installed = [rolling.configured_extension(config)]
  let extensions = extensions.Config(installed, ["rolling"])
  let assert Ok(first) = runtime.start_with_config(path, extensions)
  let assert Ok(session) = runtime.open_session(first, "restart", "/tmp")
  let history = long_history()
  let assert Ok(expected) =
    runtime.prepare_history_with(
      first,
      session,
      "model-a",
      "",
      summarize("saved"),
      history,
    )
  runtime.stop(first)

  let assert Ok(second) = runtime.start_with_config(path, extensions)
  let assert Ok(session) = runtime.open_session(second, "restart", "/tmp")
  runtime.prepare_history_with(
    second,
    session,
    "model-a",
    "",
    fn(_) { Error("must reuse saved summary") },
    history,
  )
  |> should.equal(Ok(expected))
  runtime.stop(second)
  cleanup(path)
}

pub fn rolling_config_defaults_and_validation_test() {
  rolling.default_config()
  |> should.equal(rolling.Config(None, 90, 25))
  let #(host, session) = host(rolling.Config(Some(1000), 25, 25))
  let assert Error(error) =
    runtime.prepare_history_with(
      host,
      session,
      "model",
      "",
      summarize("unused"),
      [types.User("hello")],
    )
  string.contains(error, "0 < tailPercent < triggerPercent < 100")
  |> should.be_true
  runtime.stop(host)
}
