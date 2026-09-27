import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/runtime
import albedo/openai_api/types
import gleam/list
import gleam/option.{None}
import gleam/string
import gleeunit/should
import sqlight

@external(erlang, "albedo_env_test_support", "with_home")
fn with_home(home: String, run: fn() -> a) -> a

@external(erlang, "albedo_skills_test_support", "fixture")
fn fixture() -> #(String, String, String)

@external(erlang, "albedo_skills_test_support", "write")
fn write(base: String, relative: String, content: String) -> Nil

@external(erlang, "albedo_skills_test_support", "cleanup")
fn cleanup(root: String) -> Nil

/// Folds the first input into a stored summary, as LCM would.
fn folding(name: String) -> compaction.Folds {
  compaction.Folds(name, "fixture", fn(_, _, history) {
    case history {
      [first, ..rest] ->
        Ok(compaction.Prior(
          [types.User(name <> " fold of " <> text(first))],
          rest,
        ))
      [] -> compaction.no_prior(history)
    }
  })
}

fn text(input: types.Input) -> String {
  case input {
    types.User(value) | types.Assistant(value) -> value
    _ -> ""
  }
}

fn strategy(name: String) -> extension.Extension {
  extension.Extension(
    name,
    "fixture strategy",
    [],
    [
      extension.CompactionPlugin(
        compaction.Strategy(name, fn(_, history) {
          Ok(compaction.Prepared(history, None))
        }),
      ),
    ],
    fn(_) { Ok(Nil) },
  )
}

pub fn providers_compose_in_order_test() {
  let assert Ok(ledger) = store.start(":memory:", "")
  let prior =
    compaction.compose_prior([folding("a"), folding("b")], ledger, "s")
  let assert Ok(compaction.Prior(folds, rest)) =
    prior([types.User("one"), types.User("two"), types.User("three")])
  folds
  |> should.equal([types.User("a fold of one"), types.User("b fold of two")])
  rest |> should.equal([types.User("three")])
}

pub fn snapcompact_keeps_folds_as_text_ahead_of_frames_test() {
  let folds =
    extension.Extension(
      "folds",
      "fixture fold provider",
      [],
      [extension.FoldPlugin(folding("stored"))],
      fn(_) { Ok(Nil) },
    )
  let installed = [folds, snapcompact.extension(), snapcompact.memory()]
  let assert Ok(host) =
    runtime.start_with_config(
      ":memory:",
      extensions.Config(installed, [
        "folds",
        "snapcompact",
        "snapcompact-memory",
      ]),
    )
  let assert Ok(session) = runtime.open_session(host, "snap", "/tmp")
  let history = [
    types.User("oldest"),
    types.User("u1 " <> string.repeat("a", 6000)),
    types.Assistant("a1 " <> string.repeat("b", 6000)),
    types.User("latest"),
  ]
  let assert Ok(projected) =
    runtime.compact_history_scoped(
      host,
      session,
      "claude-test",
      "claude-test",
      "",
      "system",
      fn(_) { Error("snapcompact never summarizes") },
      history,
    )
  // The fold stays readable text; only history past it becomes frames.
  let assert [types.User(fold), types.UserImage(_, _), ..] = projected
  fold |> should.equal("stored fold of oldest")
  projected |> list.last |> should.equal(Ok(types.User("latest")))
  runtime.stop(host)
}

pub fn explicit_global_strategy_displaces_a_new_default_test() {
  let #(root, _, home) = fixture()
  use <- with_home(home)
  // Chosen before "fresh" became the built-in default strategy.
  write(
    home,
    "extensions.json",
    "{\"enabled\":{\"older\":true,\"base\":false}}",
  )
  let config =
    extensions.Config([strategy("fresh"), strategy("base"), strategy("older")], [
      "fresh",
    ])
  let assert Ok(host) = runtime.start_with_config(":memory:", config)
  let assert Ok(_) = runtime.open_session(host, "a", "/tmp")
  enabled(host, "a") |> should.equal(["older"])
  runtime.stop(host)
  cleanup(root)
}

pub fn session_strategy_displaces_a_new_default_test() {
  let #(root, _, home) = fixture()
  use <- with_home(home)
  let config =
    extensions.Config([strategy("fresh"), strategy("older")], ["fresh"])
  let assert Ok(host) = runtime.start_with_config(":memory:", config)
  // A session choice recorded without an override for "fresh", as when the
  // choice predates "fresh" being installed.
  let assert Ok(_) =
    store.query(runtime.ledger(host), fn(db) {
      sqlight.exec(
        "INSERT INTO session_extensions(session,name,enabled) VALUES('a','older',1)",
        db,
      )
    })
  let assert Ok(_) = runtime.open_session(host, "a", "/tmp")
  enabled(host, "a") |> should.equal(["older"])
  runtime.stop(host)
  cleanup(root)
}

fn enabled(host: runtime.Runtime, session: String) -> List(String) {
  let assert Ok(summaries) = runtime.extension_summaries(host, session)
  summaries
  |> list.filter(fn(summary) { summary.enabled })
  |> list.map(fn(summary) { summary.name })
}
