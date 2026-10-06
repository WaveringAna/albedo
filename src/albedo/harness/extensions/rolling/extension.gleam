//// Incremental summary + recap + tail request projection.
//// Durable transcripts are inputs only: this module stores projection state separately.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/rolling/migrations/observation
import albedo/harness/settings
import albedo/harness/tool
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const recap_messages = 3

const empty_summary = "summarizer returned an empty summary"

const recap_chars_per_message = 400

pub type Config {
  Config(
    context_window_tokens: Option(Int),
    trigger_percent: Int,
    tail_percent: Int,
  )
}

type State {
  State(summary: String, cut: compaction.Cut)
}

/// The parts of a rolling projection and the request they build.
type View {
  View(
    summary: List(types.Input),
    recap: List(types.Input),
    tail: List(types.Input),
    inputs: List(types.Input),
  )
}

/// A saved row. With `cut_prefix` on `cut_hash`, `cutoff` counts user
/// messages; a row without it predates that and counts items under one source.
type Row {
  Row(summary: String, cutoff: Int, cut_hash: String)
}

/// A saved state that still matches this history, split at its cut.
type Resumed {
  Resumed(state: State, evicted: List(types.Input), tail: List(types.Input))
}

const cut_prefix = "users:"

fn default_config() -> Config {
  Config(None, 80, 25)
}

fn config_decoder() -> decode.Decoder(Config) {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field("triggerPercent", 80, decode.int)
  use tail <- decode.optional_field("tailPercent", 25, decode.int)
  decode.success(Config(capacity, trigger, tail))
}

fn validated(loaded: Result(Config, String)) -> Result(Config, String) {
  use config <- result.try(loaded)
  validate_config(config)
}

fn load_config() -> Result(Config, String) {
  validated(settings.load("rolling", config_decoder(), default_config()))
}

fn bundle(strategy: compaction.Strategy) -> extension.Extension {
  extension.Extension(
    "rolling",
    "Incremental summary, recent-user recap, and verbatim conversation tail",
    [],
    [
      extension.CompactionPlugin(strategy),
      extension.MigrationPlugin(extension.SchemaMigration(observation.apply)),
      extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["rolling_compaction_state"], session)
      }),
    ],
    initialise,
  )
}

pub fn configured_extension(config: Config) -> extension.Extension {
  bundle(strategy(fn() { validate_config(config) }))
}

pub fn extension() -> extension.Extension {
  bundle(with_settings())
}

/// The rolling strategy under the saved settings, for a strategy that falls
/// back to text for a model without image input.
pub fn with_settings() -> compaction.Strategy {
  strategy(load_config)
}

/// The strategy under the settings `resolve` answers per request.
fn strategy(resolve: fn() -> Result(Config, String)) -> compaction.Strategy {
  compaction.Strategy(
    "rolling",
    fn(context, history) {
      use config <- result.try(resolve())
      project(config, context, history)
    },
    fn(context, history) {
      use config <- result.try(resolve())
      compact(config, context, history)
    },
  )
}

/// The saved summary, recap, and tail this history still matches, or the
/// history itself, and whether it reached the trigger. A saved row the
/// history no longer matches is ignored here and replaced by the next
/// compaction.
fn project(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.View, String) {
  use compaction.Prior(folds, rest) <- result.try(context.prior(history))
  let carries_folds = folds != []
  let history = list.append(folds, rest)
  use saved <- result.try(load_state(context.store, context.session))
  let #(resumed, invalidated) = resume(saved, context.source, history)
  let current = projection(resumed, history)
  let estimated =
    context.pinned_tokens + compaction.estimate_inputs(current.inputs)
  // A saved projection this history still matches is already a compaction.
  let status_of = fn(when_absent) {
    case resumed {
      Some(_) -> "compacted"
      None -> when_absent
    }
  }
  let view = fn(status, source, capacity, due) {
    let history_source = case status, carries_folds {
      "compacted", True ->
        "durable transcript through stored folds, rolling summary, recent user recap, and verbatim tail"
      "compacted", False ->
        "durable transcript through rolling summary + recent user recap + verbatim tail"
      _, True ->
        "durable transcript through stored folds and verbatim tail; rolling observation attached"
      _, False -> "durable transcript; rolling compaction observation attached"
    }
    compaction.View(
      current.inputs,
      Some(compaction.observation(
        "rolling",
        status,
        source,
        history_source,
        config.trigger_percent,
        capacity,
        estimated,
        list.length(history),
        list.length(current.inputs),
      )),
      due,
    )
  }
  case effective_window(config.context_window_tokens, context, history) {
    None ->
      // Without a window there is no threshold to compare, but a saved
      // projection is still the user's standing instruction: honor it.
      Ok(view(
        status_of("unknown"),
        "estimated; no configured or catalogued context window",
        None,
        False,
      ))
    Some(compaction.Capacity(capacity, capacity_source)) -> {
      use _ <- result.try(compaction.fits_pinned(context, capacity))
      let source = case invalidated {
        True ->
          "estimated after the transcript changed under the saved cut; saved projection ignored"
        False -> "estimated from current request projection"
      }
      Ok(view(
        status_of("not_needed"),
        source <> "; window from " <> capacity_source,
        Some(capacity),
        compaction.triggered(
          False,
          estimated,
          Some(capacity),
          config.trigger_percent,
        ),
      ))
    }
  }
}

/// Summarizes what leaves the request into the saved summary and saves the
/// new cut, keeping a verbatim tail within the tail budget.
fn compact(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(Bool, String) {
  let compaction.Context(
    store: ledger,
    session:,
    model:,
    source:,
    pinned_tokens:,
    force:,
    summarize:,
    ..,
  ) = context
  use compaction.Prior(folds, rest) <- result.try(context.prior(history))
  let history = list.append(folds, rest)
  use compaction.Capacity(capacity, _) <- result.try(option.to_result(
    effective_window(config.context_window_tokens, context, history),
    "no configured or catalogued context window to compact against",
  ))
  use _ <- result.try(compaction.fits_pinned(context, capacity))
  use saved <- result.try(load_state(ledger, session))
  let #(previous_summary, evicted, rest) = case resume(saved, source, history) {
    #(Some(Resumed(state, evicted, tail)), _) -> #(
      Some(state.summary),
      evicted,
      tail,
    )
    #(None, _) -> #(None, [], history)
  }
  let tail_budget =
    compaction.tail_budget(
      capacity,
      compaction.estimate_inputs(history),
      force,
      config.tail_percent,
    )
  let #(newly_evicted, tail) = compaction.split_tail(rest, tail_budget)
  use _ <- result.try(compaction.require(
    history != [],
    "cannot compact an empty conversation",
  ))
  use _ <- result.try(compaction.require(
    newly_evicted != [],
    "cannot compact further without splitting the newest conversation/tool unit",
  ))
  use summary <- result.try(summarize_chunks(
    summarize,
    model,
    previous_summary,
    chunk_units(
      list.map(newly_evicted, fn(item) {
        #([item], compaction.estimate_input(item))
      }),
      int.max(1000, capacity / 2),
    ),
    int.min(2048, int.max(128, capacity / 10)),
  ))
  let next = view_of(summary, tail, history)
  // The fit guarantee belongs to a real window; a forced compaction's
  // synthetic window is a tail budget, so the projection always saves.
  use _ <- result.try(compaction.require(
    pinned_tokens + compaction.estimate_inputs(next.inputs) < capacity || force,
    "summary, recap, and indivisible recent tail do not fit the context window",
  ))
  let evicted = list.append(evicted, newly_evicted)
  use _ <- result.try(save_state(
    ledger,
    session,
    State(summary, compaction.cut_of(evicted)),
  ))
  Ok(True)
}

/// The config shape the compaction strategies share: an optional positive
/// window and tail/trigger percentages ordered inside (0, 100), reported
/// under the strategy's own name.
pub fn validate_window(
  name: String,
  context_window_tokens: Option(Int),
  trigger_percent: Int,
  tail_percent: Int,
) -> Result(Nil, String) {
  case context_window_tokens {
    Some(capacity) if capacity <= 0 ->
      Error(name <> " contextWindowTokens must be positive")
    _ ->
      compaction.require(
        trigger_percent > 0
          && trigger_percent < 100
          && tail_percent > 0
          && tail_percent < trigger_percent,
        name
          <> " percentages must satisfy 0 < tailPercent < triggerPercent < 100",
      )
  }
}

/// The window a strategy compacts against. Configuration overrides a
/// catalog; neither one is guessed from the model id. A forced compaction
/// without either still compacts, against an estimate of the request.
pub fn effective_window(
  context_window_tokens: Option(Int),
  context: compaction.Context,
  history: List(types.Input),
) -> Option(compaction.Capacity) {
  case context_window_tokens, context.capacity, context.force {
    Some(tokens), _, _ ->
      Some(compaction.Capacity(tokens, "configured contextWindowTokens"))
    None, Some(capacity), _ -> Some(capacity)
    None, None, True ->
      Some(compaction.Capacity(
        context.pinned_tokens + compaction.estimate_inputs(history),
        "estimated for manual compaction",
      ))
    None, None, False -> None
  }
}

fn validate_config(config: Config) -> Result(Config, String) {
  validate_window(
    "rolling",
    config.context_window_tokens,
    config.trigger_percent,
    config.tail_percent,
  )
  |> result.replace(config)
}

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS rolling_compaction_state(session TEXT PRIMARY KEY,summary TEXT NOT NULL,cutoff_count INTEGER NOT NULL CHECK(cutoff_count >= 0),source_hash TEXT NOT NULL);",
    )
  })
}

/// Reads the one row per session these tables keep, where no row yet is a
/// normal answer rather than an error. (`store.one` reports it as one.)
fn read_one(
  ledger: store.Store,
  sql: String,
  arguments: List(sqlight.Value),
  decoder: decode.Decoder(a),
) -> Result(Option(a), String) {
  store.read(ledger, sql, arguments, decoder)
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

fn row_decoder() -> decode.Decoder(Row) {
  use summary <- decode.field(0, decode.string)
  use cutoff <- decode.field(1, decode.int)
  use cut_hash <- decode.field(2, decode.string)
  decode.success(Row(summary, cutoff, cut_hash))
}

fn load_state(
  ledger: store.Store,
  session: String,
) -> Result(Option(Row), String) {
  read_one(
    ledger,
    "SELECT summary,cutoff_count,source_hash FROM rolling_compaction_state WHERE session=?",
    [sqlight.text(session)],
    row_decoder(),
  )
}

/// Folds evicted history into the summary one chunk at a time, so a long
/// eviction, such as a large window's history before a switch to a smaller
/// model, never asks the summarizer for more than half its window.
fn summarize_chunks(
  summarize: fn(compaction.SummaryRequest) -> Result(String, String),
  model: String,
  previous: Option(String),
  chunks: List(List(types.Input)),
  max_output_tokens: Int,
) -> Result(String, String) {
  use summary <- result.try(
    list.try_fold(chunks, previous, fn(previous, chunk) {
      summarize(compaction.SummaryRequest(
        model,
        previous,
        chunk,
        max_output_tokens,
        compaction.summary_instructions,
      ))
      |> result.map(string.trim)
      |> result.try(fn(value) {
        use _ <- result.try(compaction.require(value != "", empty_summary))
        Ok(Some(value))
      })
    }),
  )
  option.to_result(summary, empty_summary)
}

/// Groups `units`, each with its items and estimated token cost, into chunks
/// that each stay under `budget`: the unit shape both a summarizer's chunked
/// requests and an LCM leaf's source rows share.
pub fn chunk_units(units: List(#(List(a), Int)), budget: Int) -> List(List(a)) {
  chunk_runs(units, budget, [], 0, [])
}

fn chunk_runs(
  units: List(#(List(a), Int)),
  budget: Int,
  current: List(a),
  tokens: Int,
  complete: List(List(a)),
) -> List(List(a)) {
  case units {
    [] ->
      case current {
        [] -> list.reverse(complete)
        _ -> list.reverse([current, ..complete])
      }
    [unit, ..rest] ->
      case current != [] && tokens + unit.1 > budget {
        True -> chunk_runs(rest, budget, unit.0, unit.1, [current, ..complete])
        False ->
          chunk_runs(
            rest,
            budget,
            list.append(current, unit.0),
            tokens + unit.1,
            complete,
          )
      }
  }
}

fn projection(resumed: Option(Resumed), history: List(types.Input)) -> View {
  case resumed {
    None -> View([], [], history, history)
    Some(Resumed(State(summary, _), _, tail)) -> view_of(summary, tail, history)
  }
}

/// The saved summary as a model input, the recent user recap, and the
/// verbatim tail they sit before.
fn view_of(
  summary: String,
  tail: List(types.Input),
  history: List(types.Input),
) -> View {
  let folded = [
    types.User(
      "[older conversation summary; model-generated]\n"
      <> summary
      <> "\n[end older conversation summary]",
    ),
  ]
  let recap = recap(history)
  View(folded, recap, tail, list.append(folded, list.append(recap, tail)))
}

fn recap(history: List(types.Input)) -> List(types.Input) {
  let excerpts =
    history
    |> list.filter_map(fn(input) {
      case input {
        types.User(text) -> Ok(tool.excerpt(text, recap_chars_per_message))
        types.UserImage(text, _) ->
          Ok(
            tool.excerpt(text, recap_chars_per_message)
            <> "\n[image omitted from recap]",
          )
        _ -> Error(Nil)
      }
    })
    |> list.reverse
    |> list.take(recap_messages)
    |> list.reverse
  case excerpts {
    [] -> []
    values -> [
      types.User(
        "[recent user excerpts; verbatim and possibly truncated]\n--- user excerpt ---\n"
        <> string.join(values, "\n--- user excerpt ---\n")
        <> "\n[end recent user excerpts]",
      ),
    ]
  }
}

/// The saved state this history still matches, and whether a saved row was
/// invalidated. A legacy row validates the way it was written, by item count
/// under one source; it resumes as a user-message cut, which the next
/// compaction saves in its place.
fn resume(
  saved: Option(Row),
  source: String,
  history: List(types.Input),
) -> #(Option(Resumed), Bool) {
  case saved {
    None -> #(None, False)
    Some(Row(summary, cutoff, cut_hash)) ->
      case string.split_once(cut_hash, cut_prefix) {
        Ok(#("", fingerprint)) -> {
          let state = State(summary, compaction.Cut(cutoff, fingerprint))
          case compaction.resume(history, state.cut) {
            Ok(#(evicted, tail)) -> #(
              Some(Resumed(state, evicted, tail)),
              False,
            )
            Error(Nil) -> #(None, True)
          }
        }
        _ -> {
          let #(evicted, tail) = list.split(history, cutoff)
          let matches =
            list.length(evicted) == cutoff
            && {
              compaction.fingerprint(#(source, evicted)) == cut_hash
              // A hash saved before images were stored covered their
              // payload bytes; checking it reads them.
              || has_images(evicted)
              && legacy_fingerprint(#(source, evicted)) == Ok(cut_hash)
            }
          case matches, tail {
            True, [types.User(_), ..] | True, [types.UserImage(_, _), ..] -> {
              let state = State(summary, compaction.cut_of(evicted))
              #(Some(Resumed(state, evicted, tail)), False)
            }
            _, _ -> #(None, True)
          }
        }
      }
  }
}

fn has_images(inputs: List(types.Input)) -> Bool {
  list.any(inputs, fn(input) {
    case input {
      types.UserImage(..) -> True
      types.ToolOutput(images: [_, ..], ..) -> True
      _ -> False
    }
  })
}

fn save_state(
  ledger: store.Store,
  session: String,
  state: State,
) -> Result(Nil, String) {
  store.write(
    ledger,
    "INSERT INTO rolling_compaction_state(session,summary,cutoff_count,source_hash) VALUES(?,?,?,?) ON CONFLICT(session) DO UPDATE SET summary=excluded.summary,cutoff_count=excluded.cutoff_count,source_hash=excluded.source_hash",
    [
      sqlight.text(session),
      sqlight.text(state.summary),
      sqlight.int(state.cut.users),
      sqlight.text(cut_prefix <> state.cut.fingerprint),
    ],
  )
}

@external(erlang, "albedo_rolling", "legacy_fingerprint")
fn legacy_fingerprint(value: a) -> Result(String, Nil)
