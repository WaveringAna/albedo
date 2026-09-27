//// Incremental summary + recap + tail request projection.
//// Durable transcripts are inputs only: this module stores projection state separately.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const recap_messages = 3

const recap_chars_per_message = 400

pub type Config {
  Config(
    context_window_tokens: Option(Int),
    trigger_percent: Int,
    tail_percent: Int,
  )
}

pub type Observation {
  Observation(
    strategy: String,
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

pub fn default_config() -> Config {
  Config(None, 90, 25)
}

pub fn config_decoder() {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field("triggerPercent", 90, decode.int)
  use tail <- decode.optional_field("tailPercent", 25, decode.int)
  decode.success(Config(capacity, trigger, tail))
}

pub fn load_config() -> Result(Config, String) {
  use config <- result.try(settings.load(
    "rolling",
    config_decoder(),
    default_config(),
  ))
  validate_config(config)
}

pub fn load_config_at(home: String) -> Result(Config, String) {
  use config <- result.try(settings.load_at(
    home,
    "rolling",
    config_decoder(),
    default_config(),
  ))
  validate_config(config)
}

pub fn configured_extension(config: Config) -> extension.Extension {
  extension.Extension(
    "rolling",
    "Incremental summary, recent-user recap, and verbatim conversation tail",
    [],
    [extension.CompactionPlugin(strategy(config))],
    initialise,
  )
}

pub fn extension() -> extension.Extension {
  extension.Extension(
    "rolling",
    "Incremental summary, recent-user recap, and verbatim conversation tail",
    [],
    [
      extension.CompactionPlugin(compaction.Strategy(
        "rolling",
        prepare_with_settings,
      )),
    ],
    initialise,
  )
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

pub fn strategy(config: Config) -> compaction.Strategy {
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
  use inputs <- result.try(prepare(config, context, folded))
  // Diagnostics must not fail a request after its projection was committed.
  let recorded =
    observation(context.store, context.session) |> result.unwrap(None)
  let observed = case recorded {
    Some(recorded) ->
      Some(compaction.Observation(
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
        Some(100 - recorded.trigger_percent),
        recorded.capacity_tokens,
        Some(recorded.estimated_tokens),
        Some("local byte-based estimate; not provider token usage"),
        Some(recorded.original_items),
        Some(recorded.prepared_items),
      ))
    None -> None
  }
  Ok(compaction.Prepared(inputs, observed))
}

fn validate_config(config: Config) -> Result(Config, String) {
  case config.context_window_tokens {
    Some(capacity) if capacity <= 0 ->
      Error("rolling contextWindowTokens must be positive")
    _ ->
      case
        config.trigger_percent > 0
        && config.trigger_percent < 100
        && config.tail_percent > 0
        && config.tail_percent < config.trigger_percent
      {
        True -> Ok(config)
        False ->
          Error(
            "rolling percentages must satisfy 0 < tailPercent < triggerPercent < 100",
          )
      }
  }
}

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS rolling_compaction_state(session TEXT PRIMARY KEY,summary TEXT NOT NULL,cutoff_count INTEGER NOT NULL CHECK(cutoff_count >= 0),source_hash TEXT NOT NULL); CREATE TABLE IF NOT EXISTS rolling_compaction_observation(session TEXT PRIMARY KEY,status TEXT NOT NULL,source TEXT NOT NULL,capacity_tokens INTEGER,estimated_tokens INTEGER NOT NULL,trigger_percent INTEGER NOT NULL,original_items INTEGER NOT NULL,original_bytes INTEGER NOT NULL,summary_items INTEGER NOT NULL,summary_bytes INTEGER NOT NULL,recap_items INTEGER NOT NULL,recap_bytes INTEGER NOT NULL,tail_items INTEGER NOT NULL,tail_bytes INTEGER NOT NULL,prepared_items INTEGER NOT NULL,prepared_bytes INTEGER NOT NULL);",
      db,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

pub fn observation(
  ledger: store.Store,
  session: String,
) -> Result(Option(Observation), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT status,source,capacity_tokens,estimated_tokens,trigger_percent,original_items,original_bytes,summary_items,summary_bytes,recap_items,recap_bytes,tail_items,tail_bytes,prepared_items,prepared_bytes FROM rolling_compaction_observation WHERE session=?",
      db,
      [sqlight.text(session)],
      observation_decoder(),
    )
    |> result.map_error(fn(error) { error.message })
    |> result.map(fn(rows) { list.first(rows) |> option_from_result })
  })
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(item) -> Some(item)
    Error(_) -> None
  }
}

fn observation_decoder() {
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
    "rolling",
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

fn row_decoder() {
  use summary <- decode.field(0, decode.string)
  use cutoff <- decode.field(1, decode.int)
  use cut_hash <- decode.field(2, decode.string)
  decode.success(Row(summary, cutoff, cut_hash))
}

fn load_state(
  ledger: store.Store,
  session: String,
) -> Result(Option(Row), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT summary,cutoff_count,source_hash FROM rolling_compaction_state WHERE session=?",
      db,
      [sqlight.text(session)],
      row_decoder(),
    )
    |> result.map_error(fn(error) { error.message })
    |> result.map(fn(rows) { list.first(rows) |> option_from_result })
  })
}

fn prepare(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(List(types.Input), String) {
  let compaction.Context(
    ledger,
    session,
    _,
    model,
    source,
    pinned_tokens,
    catalogued,
    force,
    summarize,
    _,
    _,
  ) = context
  let original_items = list.length(history)
  let original_bytes = compaction.inputs_bytes(history)
  // Configuration overrides a catalog; neither one is guessed from the model id.
  let window = case config.context_window_tokens {
    Some(tokens) ->
      Some(compaction.Capacity(tokens, "configured contextWindowTokens"))
    None ->
      case catalogued, force {
        None, True ->
          Some(compaction.Capacity(
            pinned_tokens + compaction.estimate_inputs(history),
            "estimated for manual compaction",
          ))
        _, _ -> catalogued
      }
  }
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
  case window {
    None -> {
      // Without a window there is no threshold to compare, but a saved
      // projection is still the user's standing instruction: honor it.
      let status = case resumed {
        Some(_) -> "compacted"
        None -> "unknown"
      }
      use _ <- result.try(save_observation(
        ledger,
        session,
        observation_for(
          status,
          "estimated; no configured or catalogued context window",
          None,
          pinned_tokens + compaction.estimate_inputs(current.3),
          config,
          original_items,
          original_bytes,
          current.0,
          current.1,
          current.2,
        ),
      ))
      Ok(current.3)
    }
    Some(compaction.Capacity(capacity, capacity_source)) -> {
      let estimated = pinned_tokens + compaction.estimate_inputs(current.3)
      case pinned_tokens >= capacity {
        True -> {
          let observation =
            observation_for(
              "limitation",
              "estimated pinned system, extension context, and tool schemas; window from "
                <> capacity_source,
              Some(capacity),
              estimated,
              config,
              original_items,
              original_bytes,
              current.0,
              current.1,
              current.2,
            )
          let _ = save_observation(ledger, session, observation)
          Error(
            "context window is not large enough for pinned system, extension context, and tool schemas",
          )
        }
        False if !force && estimated * 100 < capacity * config.trigger_percent -> {
          let status = case resumed {
            Some(_) -> "compacted"
            None -> "not_needed"
          }
          let source = case invalidated {
            True ->
              "estimated after the transcript changed under the saved cut; saved projection reset"
            False -> "estimated from current request projection"
          }
          let source = source <> "; window from " <> capacity_source
          use _ <- result.try(save_observation(
            ledger,
            session,
            observation_for(
              status,
              source,
              Some(capacity),
              estimated,
              config,
              original_items,
              original_bytes,
              current.0,
              current.1,
              current.2,
            ),
          ))
          Ok(current.3)
        }
        False -> {
          let #(previous_summary, evicted, rest) = case resumed {
            Some(Resumed(state, evicted, tail)) -> #(
              Some(state.summary),
              evicted,
              tail,
            )
            None -> #(None, [], history)
          }
          let tail_budget = case force {
            True ->
              int.min(capacity, compaction.estimate_inputs(history))
              * config.tail_percent
              / 100
            False -> capacity * config.tail_percent / 100
          }
          let #(newly_evicted, tail) = compaction.split_tail(rest, tail_budget)
          use _ <- result.try(case history, newly_evicted {
            [], _ -> Error("cannot compact an empty conversation")
            _, [] ->
              Error(
                "cannot compact further without splitting the newest conversation/tool unit",
              )
            _, _ -> Ok(Nil)
          })
          use summary <- result.try(summarize_chunks(
            summarize,
            model,
            previous_summary,
            chunks(newly_evicted, int.max(1000, capacity / 2), 0, [], []),
            int.min(2048, int.max(128, capacity / 10)),
          ))
          let evicted = list.append(evicted, newly_evicted)
          let next_state = State(summary, compaction.cut_of(evicted))
          let next =
            projection(Some(Resumed(next_state, evicted, tail)), history)
          let next_estimated =
            pinned_tokens + compaction.estimate_inputs(next.3)
          // The fit guarantee belongs to a real window; a forced compaction's
          // synthetic window is a tail budget, so the projection always saves.
          use _ <- result.try(case next_estimated < capacity || force {
            True -> Ok(Nil)
            False ->
              Error(
                "summary, recap, and indivisible recent tail do not fit the context window",
              )
          })
          let observation =
            observation_for(
              "compacted",
              "estimated from current request projection; window from "
                <> capacity_source,
              Some(capacity),
              next_estimated,
              config,
              original_items,
              original_bytes,
              next.0,
              next.1,
              next.2,
            )
          use _ <- result.try(save_compaction(
            ledger,
            session,
            next_state,
            observation,
          ))
          Ok(next.3)
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
      ))
      |> result.map(string.trim)
      |> result.try(fn(value) {
        case value == "" {
          True -> Error("summarizer returned an empty summary")
          False -> Ok(Some(value))
        }
      })
    }),
  )
  option.to_result(summary, "summarizer returned an empty summary")
}

fn chunks(
  items: List(types.Input),
  budget: Int,
  tokens: Int,
  current: List(types.Input),
  complete: List(List(types.Input)),
) -> List(List(types.Input)) {
  case items, current {
    [], [] -> list.reverse(complete)
    [], _ -> list.reverse([list.reverse(current), ..complete])
    [item, ..rest], _ -> {
      let cost = compaction.estimate_input(item)
      case current != [] && tokens + cost > budget {
        True ->
          chunks(rest, budget, cost, [item], [list.reverse(current), ..complete])
        False ->
          chunks(rest, budget, tokens + cost, [item, ..current], complete)
      }
    }
  }
}

/// #(summary inputs, recap inputs, tail inputs, complete projection)
fn projection(
  resumed: Option(Resumed),
  history: List(types.Input),
) -> #(
  List(types.Input),
  List(types.Input),
  List(types.Input),
  List(types.Input),
) {
  case resumed {
    None -> #([], [], history, history)
    Some(Resumed(state, _, tail)) -> {
      let summary = [
        types.User(
          "[older conversation summary; model-generated]\n"
          <> state.summary
          <> "\n[end older conversation summary]",
        ),
      ]
      let recap = recap(history)
      #(summary, recap, tail, list.append(summary, list.append(recap, tail)))
    }
  }
}

fn recap(history: List(types.Input)) -> List(types.Input) {
  let excerpts =
    history
    |> list.filter_map(fn(input) {
      case input {
        types.User(text) -> Ok(bounded_excerpt(text))
        types.UserImage(text, _) ->
          Ok(bounded_excerpt(text) <> "\n[image omitted from recap]")
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

fn bounded_excerpt(text: String) -> String {
  case string.length(text) > recap_chars_per_message {
    True -> string.slice(text, 0, recap_chars_per_message) <> "…"
    False -> text
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
              source_fingerprint(source, evicted) == cut_hash
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
  store.query(ledger, fn(db) {
    sqlight.query(
      "UPDATE rolling_compaction_state SET cutoff_count=?,source_hash=? WHERE session=?",
      db,
      [
        sqlight.int(cut.users),
        sqlight.text(cut_prefix <> cut.fingerprint),
        sqlight.text(session),
      ],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

fn observation_for(
  status: String,
  source: String,
  capacity: Option(Int),
  estimated: Int,
  config: Config,
  original_items: Int,
  original_bytes: Int,
  summary: List(types.Input),
  recap: List(types.Input),
  tail: List(types.Input),
) -> Observation {
  Observation(
    "rolling",
    status,
    source,
    capacity,
    estimated,
    config.trigger_percent,
    original_items,
    original_bytes,
    list.length(summary),
    compaction.inputs_bytes(summary),
    list.length(recap),
    compaction.inputs_bytes(recap),
    list.length(tail),
    compaction.inputs_bytes(tail),
    list.length(summary) + list.length(recap) + list.length(tail),
    compaction.inputs_bytes(summary)
      + compaction.inputs_bytes(recap)
      + compaction.inputs_bytes(tail),
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
    use _ <- result.try(
      sqlight.exec("BEGIN IMMEDIATE", db)
      |> result.map_error(fn(error) { error.message }),
    )
    let written = {
      use _ <- result.try(
        sqlight.query(
          "INSERT INTO rolling_compaction_state(session,summary,cutoff_count,source_hash) VALUES(?,?,?,?) ON CONFLICT(session) DO UPDATE SET summary=excluded.summary,cutoff_count=excluded.cutoff_count,source_hash=excluded.source_hash",
          db,
          [
            sqlight.text(session),
            sqlight.text(state.summary),
            sqlight.int(state.cut.users),
            sqlight.text(cut_prefix <> state.cut.fingerprint),
          ],
          decode.dynamic,
        )
        |> result.replace(Nil)
        |> result.map_error(fn(error) { error.message }),
      )
      write_observation(db, session, observation)
    }
    case written {
      Ok(_) ->
        sqlight.exec("COMMIT", db)
        |> result.replace(Nil)
        |> result.map_error(fn(error) { error.message })
      Error(error) -> {
        let _ = sqlight.exec("ROLLBACK", db)
        Error(error)
      }
    }
  })
}

fn write_observation(
  db,
  session: String,
  observation: Observation,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO rolling_compaction_observation(session,status,source,capacity_tokens,estimated_tokens,trigger_percent,original_items,original_bytes,summary_items,summary_bytes,recap_items,recap_bytes,tail_items,tail_bytes,prepared_items,prepared_bytes) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(session) DO UPDATE SET status=excluded.status,source=excluded.source,capacity_tokens=excluded.capacity_tokens,estimated_tokens=excluded.estimated_tokens,trigger_percent=excluded.trigger_percent,original_items=excluded.original_items,original_bytes=excluded.original_bytes,summary_items=excluded.summary_items,summary_bytes=excluded.summary_bytes,recap_items=excluded.recap_items,recap_bytes=excluded.recap_bytes,tail_items=excluded.tail_items,tail_bytes=excluded.tail_bytes,prepared_items=excluded.prepared_items,prepared_bytes=excluded.prepared_bytes",
    db,
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
    decode.dynamic,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) { error.message })
}

fn delete_state(ledger: store.Store, session: String) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "DELETE FROM rolling_compaction_state WHERE session=?",
      db,
      [sqlight.text(session)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

fn source_fingerprint(source: String, inputs: List(types.Input)) -> String {
  compaction.fingerprint(#(source, inputs))
}

@external(erlang, "albedo_rolling", "legacy_fingerprint")
fn legacy_fingerprint(value: a) -> Result(String, Nil)
