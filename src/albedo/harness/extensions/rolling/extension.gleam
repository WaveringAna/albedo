//// Incremental summary + recap + tail request projection.
//// Durable transcripts are inputs only: this module stores projection state separately.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
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

type Observation {
  Observation(
    status: String,
    source: String,
    capacity_tokens: Option(Int),
    estimated_tokens: Int,
    trigger_percent: Int,
    original_items: Int,
    original_bytes: Int,
    summary_items: Int,
    summary_bytes: Int,
    recap_items: Int,
    recap_bytes: Int,
    tail_items: Int,
    tail_bytes: Int,
    prepared_items: Int,
    prepared_bytes: Int,
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
    [extension.CompactionPlugin(strategy)],
    initialise,
  )
}

pub fn configured_extension(config: Config) -> extension.Extension {
  bundle(strategy(config))
}

pub fn extension() -> extension.Extension {
  bundle(compaction.Strategy("rolling", prepare_with_settings))
}

/// The rolling projection under the saved settings, for a strategy that falls
/// back to text for a model without image input.
pub fn prepare_with_settings(
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  use config <- result.try(load_config())
  prepare_view(config, context, history)
}

fn strategy(config: Config) -> compaction.Strategy {
  compaction.Strategy("rolling", fn(context, history) {
    use valid <- result.try(validate_config(config))
    prepare_view(valid, context, history)
  })
}

fn prepare_view(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  use compaction.Prior(folds, rest) <- result.try(context.prior(history))
  let folded = list.append(folds, rest)
  let carries_folds = folds != []
  use #(inputs, compacted) <- result.try(prepare(config, context, folded))
  // Diagnostics must not fail a request after its projection was committed.
  let recorded =
    observation(context.store, context.session) |> result.unwrap(None)
  let observed =
    option.map(recorded, fn(recorded) {
      compaction.observation(
        "rolling",
        recorded.status,
        recorded.source,
        case recorded.status, carries_folds {
          "compacted", True ->
            "durable transcript through stored folds, rolling summary, recent user recap, and verbatim tail"
          "compacted", False ->
            "durable transcript through rolling summary + recent user recap + verbatim tail"
          _, True ->
            "durable transcript through stored folds and verbatim tail; rolling observation attached"
          _, False ->
            "durable transcript; rolling compaction observation attached"
        },
        recorded.trigger_percent,
        recorded.capacity_tokens,
        recorded.estimated_tokens,
        recorded.original_items,
        recorded.prepared_items,
      )
    })
  Ok(compaction.Prepared(inputs, observed, compacted))
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
      "CREATE TABLE IF NOT EXISTS rolling_compaction_state(session TEXT PRIMARY KEY,summary TEXT NOT NULL,cutoff_count INTEGER NOT NULL CHECK(cutoff_count >= 0),source_hash TEXT NOT NULL); CREATE TABLE IF NOT EXISTS rolling_compaction_observation(session TEXT PRIMARY KEY,status TEXT NOT NULL,source TEXT NOT NULL,capacity_tokens INTEGER,estimated_tokens INTEGER NOT NULL,trigger_percent INTEGER NOT NULL,original_items INTEGER NOT NULL,original_bytes INTEGER NOT NULL,summary_items INTEGER NOT NULL,summary_bytes INTEGER NOT NULL,recap_items INTEGER NOT NULL,recap_bytes INTEGER NOT NULL,tail_items INTEGER NOT NULL,tail_bytes INTEGER NOT NULL,prepared_items INTEGER NOT NULL,prepared_bytes INTEGER NOT NULL);",
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

fn observation(
  ledger: store.Store,
  session: String,
) -> Result(Option(Observation), String) {
  read_one(
    ledger,
    "SELECT status,source,capacity_tokens,estimated_tokens,trigger_percent,original_items,original_bytes,summary_items,summary_bytes,recap_items,recap_bytes,tail_items,tail_bytes,prepared_items,prepared_bytes FROM rolling_compaction_observation WHERE session=?",
    [sqlight.text(session)],
    observation_decoder(),
  )
}

fn observation_decoder() -> decode.Decoder(Observation) {
  use status <- decode.field(0, decode.string)
  use source <- decode.field(1, decode.string)
  use capacity <- decode.field(2, decode.optional(decode.int))
  use estimated <- decode.field(3, decode.int)
  use trigger <- decode.field(4, decode.int)
  use original_items <- decode.field(5, decode.int)
  use original_bytes <- decode.field(6, decode.int)
  use summary_items <- decode.field(7, decode.int)
  use summary_bytes <- decode.field(8, decode.int)
  use recap_items <- decode.field(9, decode.int)
  use recap_bytes <- decode.field(10, decode.int)
  use tail_items <- decode.field(11, decode.int)
  use tail_bytes <- decode.field(12, decode.int)
  use prepared_items <- decode.field(13, decode.int)
  use prepared_bytes <- decode.field(14, decode.int)
  decode.success(Observation(
    status,
    source,
    capacity,
    estimated,
    trigger,
    original_items,
    original_bytes,
    summary_items,
    summary_bytes,
    recap_items,
    recap_bytes,
    tail_items,
    tail_bytes,
    prepared_items,
    prepared_bytes,
  ))
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

fn prepare(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(#(List(types.Input), Bool), String) {
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
  let window = effective_window(config.context_window_tokens, context, history)
  use saved <- result.try(load_state(ledger, session))
  use #(resumed, invalidated) <- result.try(resume(
    ledger,
    session,
    saved,
    source,
    history,
  ))
  use _ <- result.try(case invalidated {
    True -> delete_state(ledger, session)
    False -> Ok(Nil)
  })
  let current = projection(resumed, history)
  // A saved projection this history still matches is already a compaction;
  // each branch names what to report when there is none.
  let status_of = fn(when_absent) {
    case resumed {
      Some(_) -> "compacted"
      None -> when_absent
    }
  }
  // The observation's shape is fixed; only the status, window facts, and the
  // projection it describes vary per branch.
  let observe = fn(status, provenance, capacity, tokens, view: View) {
    observation_for(
      status,
      provenance,
      capacity,
      tokens,
      config.trigger_percent,
      history,
      view,
    )
  }
  // A branch that sends the projection as it stands records what it observed.
  let report = fn(status, provenance, capacity, tokens, view: View) {
    use _ <- result.try(save_observation(
      ledger,
      session,
      observe(status, provenance, capacity, tokens, view),
    ))
    Ok(#(view.inputs, False))
  }
  case window {
    None ->
      // Without a window there is no threshold to compare, but a saved
      // projection is still the user's standing instruction: honor it.
      report(
        status_of("unknown"),
        "estimated; no configured or catalogued context window",
        None,
        pinned_tokens + compaction.estimate_inputs(current.inputs),
        current,
      )
    Some(compaction.Capacity(capacity, capacity_source)) -> {
      let estimated = pinned_tokens + compaction.estimate_inputs(current.inputs)
      case pinned_tokens >= capacity {
        True -> {
          let _ =
            report(
              "limitation",
              "estimated pinned system, extension context, and tool schemas; window from "
                <> capacity_source,
              Some(capacity),
              estimated,
              current,
            )
          Error(
            "context window is not large enough for pinned system, extension context, and tool schemas",
          )
        }
        False ->
          case
            compaction.triggered(
              force,
              estimated,
              Some(capacity),
              config.trigger_percent,
            )
          {
            False -> {
              let source = case invalidated {
                True ->
                  "estimated after the transcript changed under the saved cut; saved projection reset"
                False -> "estimated from current request projection"
              }
              report(
                status_of("not_needed"),
                source <> "; window from " <> capacity_source,
                Some(capacity),
                estimated,
                current,
              )
            }
            True -> {
              let #(previous_summary, evicted, rest) = case resumed {
                Some(Resumed(state, evicted, tail)) -> #(
                  Some(state.summary),
                  evicted,
                  tail,
                )
                None -> #(None, [], history)
              }
              let tail_budget =
                compaction.tail_budget(
                  capacity,
                  compaction.estimate_inputs(history),
                  force,
                  config.tail_percent,
                )
              let #(newly_evicted, tail) =
                compaction.split_tail(rest, tail_budget)
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
              let evicted = list.append(evicted, newly_evicted)
              let next_state = State(summary, compaction.cut_of(evicted))
              let next = view_of(summary, tail, history)
              let next_estimated =
                pinned_tokens + compaction.estimate_inputs(next.inputs)
              // The fit guarantee belongs to a real window; a forced compaction's
              // synthetic window is a tail budget, so the projection always saves.
              use _ <- result.try(compaction.require(
                next_estimated < capacity || force,
                "summary, recap, and indivisible recent tail do not fit the context window",
              ))
              let observation =
                observe(
                  "compacted",
                  "estimated from current request projection; window from "
                    <> capacity_source,
                  Some(capacity),
                  next_estimated,
                  next,
                )
              use _ <- result.try(save_compaction(
                ledger,
                session,
                next_state,
                observation,
              ))
              Ok(#(next.inputs, True))
            }
          }
      }
    }
  }
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
/// under one source, and is rewritten as a user-message cut once it matches.
fn resume(
  ledger: store.Store,
  session: String,
  saved: Option(Row),
  source: String,
  history: List(types.Input),
) -> Result(#(Option(Resumed), Bool), String) {
  case saved {
    None -> Ok(#(None, False))
    Some(Row(summary, cutoff, cut_hash)) ->
      case string.split_once(cut_hash, cut_prefix) {
        Ok(#("", fingerprint)) -> {
          let state = State(summary, compaction.Cut(cutoff, fingerprint))
          case compaction.resume(history, state.cut) {
            Ok(#(evicted, tail)) ->
              Ok(#(Some(Resumed(state, evicted, tail)), False))
            Error(Nil) -> Ok(#(None, True))
          }
        }
        _ -> {
          let #(evicted, tail) = list.split(history, cutoff)
          let matches =
            list.length(evicted) == cutoff
            && {
              compaction.fingerprint(#(source, evicted)) == cut_hash
              // A hash saved before images were stored covered their
              // payload bytes; checking it reads them once.
              || has_images(evicted)
              && legacy_fingerprint(#(source, evicted)) == Ok(cut_hash)
            }
          case matches, tail {
            True, [types.User(_), ..] | True, [types.UserImage(_, _), ..] -> {
              let state = State(summary, compaction.cut_of(evicted))
              use _ <- result.try(save_cut(ledger, session, state.cut))
              Ok(#(Some(Resumed(state, evicted, tail)), False))
            }
            _, _ -> Ok(#(None, True))
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

fn save_cut(
  ledger: store.Store,
  session: String,
  cut: compaction.Cut,
) -> Result(Nil, String) {
  store.write(
    ledger,
    "UPDATE rolling_compaction_state SET cutoff_count=?,source_hash=? WHERE session=?",
    [
      sqlight.int(cut.users),
      sqlight.text(cut_prefix <> cut.fingerprint),
      sqlight.text(session),
    ],
  )
}

fn observation_for(
  status: String,
  source: String,
  capacity: Option(Int),
  estimated: Int,
  trigger_percent: Int,
  original: List(types.Input),
  view: View,
) -> Observation {
  let measure = fn(inputs) {
    #(list.length(inputs), compaction.inputs_bytes(inputs))
  }
  let #(original_items, original_bytes) = measure(original)
  let #(summary_items, summary_bytes) = measure(view.summary)
  let #(recap_items, recap_bytes) = measure(view.recap)
  let #(tail_items, tail_bytes) = measure(view.tail)
  Observation(
    status,
    source,
    capacity,
    estimated,
    trigger_percent,
    original_items,
    original_bytes,
    summary_items,
    summary_bytes,
    recap_items,
    recap_bytes,
    tail_items,
    tail_bytes,
    summary_items + recap_items + tail_items,
    summary_bytes + recap_bytes + tail_bytes,
  )
}

fn save_observation(
  ledger: store.Store,
  session: String,
  observation: Observation,
) -> Result(Nil, String) {
  store.query(ledger, fn(db) { write_observation(db, session, observation) })
}

fn save_compaction(
  ledger: store.Store,
  session: String,
  state: State,
  observation: Observation,
) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(
        store.run(
          db,
          "INSERT INTO rolling_compaction_state(session,summary,cutoff_count,source_hash) VALUES(?,?,?,?) ON CONFLICT(session) DO UPDATE SET summary=excluded.summary,cutoff_count=excluded.cutoff_count,source_hash=excluded.source_hash",
          [
            sqlight.text(session),
            sqlight.text(state.summary),
            sqlight.int(state.cut.users),
            sqlight.text(cut_prefix <> state.cut.fingerprint),
          ],
        ),
      )
      write_observation(db, session, observation)
    })
  })
}

fn write_observation(
  db: sqlight.Connection,
  session: String,
  observation: Observation,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO rolling_compaction_observation(session,status,source,capacity_tokens,estimated_tokens,trigger_percent,original_items,original_bytes,summary_items,summary_bytes,recap_items,recap_bytes,tail_items,tail_bytes,prepared_items,prepared_bytes) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(session) DO UPDATE SET status=excluded.status,source=excluded.source,capacity_tokens=excluded.capacity_tokens,estimated_tokens=excluded.estimated_tokens,trigger_percent=excluded.trigger_percent,original_items=excluded.original_items,original_bytes=excluded.original_bytes,summary_items=excluded.summary_items,summary_bytes=excluded.summary_bytes,recap_items=excluded.recap_items,recap_bytes=excluded.recap_bytes,tail_items=excluded.tail_items,tail_bytes=excluded.tail_bytes,prepared_items=excluded.prepared_items,prepared_bytes=excluded.prepared_bytes",
    [
      sqlight.text(session),
      sqlight.text(observation.status),
      sqlight.text(observation.source),
      sqlight.nullable(sqlight.int, observation.capacity_tokens),
      sqlight.int(observation.estimated_tokens),
      sqlight.int(observation.trigger_percent),
      sqlight.int(observation.original_items),
      sqlight.int(observation.original_bytes),
      sqlight.int(observation.summary_items),
      sqlight.int(observation.summary_bytes),
      sqlight.int(observation.recap_items),
      sqlight.int(observation.recap_bytes),
      sqlight.int(observation.tail_items),
      sqlight.int(observation.tail_bytes),
      sqlight.int(observation.prepared_items),
      sqlight.int(observation.prepared_bytes),
    ],
  )
}

fn delete_state(ledger: store.Store, session: String) -> Result(Nil, String) {
  store.write(ledger, "DELETE FROM rolling_compaction_state WHERE session=?", [
    sqlight.text(session),
  ])
}

@external(erlang, "albedo_rolling", "legacy_fingerprint")
fn legacy_fingerprint(value: a) -> Result(String, Nil)
