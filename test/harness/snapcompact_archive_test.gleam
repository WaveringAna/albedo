import albedo/daemon/conversation
import albedo/harness/extensions
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/extensions/snapcompact/transcript
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should

// What snapcompact-memory adds: the archive as text folds for another
// strategy, and the transcript tools. Frames need albedo-render built.

fn host() {
  let config = snapcompact.Config(Some(10_000), 90, 10, 60, None, True)
  let installed = [
    snapcompact.configured_extension(config),
    rolling.configured_extension(rolling.Config(Some(1_000_000), 90, 25)),
    snapcompact.memory(),
  ]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, ["snapcompact", "snapcompact-memory"]),
    )
  let ledger = runtime.ledger(host)
  let assert Ok(_) = conversation.initialise(ledger)
  let assert Ok(_) =
    conversation.create(
      ledger,
      conversation.Info(
        "snap",
        "new session",
        "/tmp",
        "provider",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(session) = runtime.open_session(host, "snap", "/tmp")
  #(host, session)
}

fn turns(n: Int) -> List(types.Input) {
  list.repeat(Nil, n)
  |> list.index_map(fn(_, index) { index + 1 })
  |> list.flat_map(fn(i) {
    [
      types.User("u" <> int.to_string(i) <> " " <> string.repeat("a", 2000)),
      types.Assistant(
        "a" <> int.to_string(i) <> " " <> string.repeat("b", 2000),
      ),
    ]
  })
}

fn prepare(host, session, history) {
  let assert Ok(prepared) =
    runtime.prepare_history_with(
      host,
      session,
      "model",
      "",
      fn(_) { Error("must not summarize") },
      history,
    )
  prepared
}

pub fn rolling_reads_the_archive_as_text_folds_test() {
  let #(host, session) = host()
  let history = turns(6)
  let assert Ok(_) =
    runtime.compact_history_scoped(
      host,
      session,
      "model",
      "source",
      "",
      "",
      fn(_) { Error("must not summarize") },
      history,
    )
  let assert Ok(Some(archive)) =
    snapcompact.load_archive(runtime.ledger(host), "snap")
  let assert Ok(session) =
    runtime.reload_extension(host, "snap", "/tmp", "rolling", True)
  let projected = prepare(host, session, history)
  let #(folds, rest) =
    list.split_while(projected, fn(input) {
      case input {
        types.User(text) ->
          string.starts_with(text, "[snapcompact archive page")
        _ -> False
      }
    })
  let assert [types.User(first), ..] = folds
  first |> string.contains("u1 aaa") |> should.be_true
  // The archive's pages stand in for exactly the history its cut covers.
  let covered = archive.cut.users * 2
  rest |> should.equal(list.drop(history, covered))
  runtime.stop(host)
}

pub fn transcript_tools_page_the_original_rows_test() {
  let #(host, _) = host()
  let ledger = runtime.ledger(host)
  let assert Ok(_) =
    conversation.commit_from(
      ledger,
      "snap",
      turns(2),
      conversation.Idle,
      Some("provider"),
    )
  let assert Ok(found) = transcript.grep(ledger, "snap", "U2 AAA", 5, 0)
  found |> string.contains("\"count\":1") |> should.be_true
  let assert Ok(page) = transcript.read(ledger, "snap", 0, 0, 30)
  page |> string.contains("u1 aaa") |> should.be_true
  page |> string.contains("\"next_offset\":30") |> should.be_true
  runtime.stop(host)
}

/// A forced compaction far below a large window still archives: its tail is
/// a share of what the request holds, not of the window. The observation
/// reports the window the budget used.
pub fn forced_compaction_archives_under_a_large_window_test() {
  let config = snapcompact.Config(Some(1_000_000), 90, 10, 20, None, True)
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(
        [snapcompact.configured_extension(config), snapcompact.memory()],
        ["snapcompact", "snapcompact-memory"],
      ),
    )
  let assert Ok(session) = runtime.open_session(host, "big", "/tmp")
  let assert Ok(prepared) =
    runtime.prepare_view_scoped(
      host,
      session,
      "model",
      "source",
      "",
      "",
      fn(_) { Error("must not summarize") },
      turns(3),
      True,
    )
  let assert Ok(Some(archive)) =
    snapcompact.load_archive(runtime.ledger(host), "big")
  should.be_true(archive.cut.users > 0)
  let assert Some(observation) = prepared.observation
  observation.status |> should.equal("compacted")
  observation.input_limit_tokens |> should.equal(Some(1_000_000))
  observation.trigger_free_percent |> should.equal(Some(10))
  runtime.stop(host)
}
