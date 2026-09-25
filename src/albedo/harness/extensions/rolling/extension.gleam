//// Incremental summary + recap + tail request projection.
//// Durable transcripts are inputs only: this module stores projection state separately.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/lcm/extension as lcm
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
  State(summary: String, cutoff_count: Int, source_hash: String)
}

type Unit {
  Unit(items: List(types.Input), tokens: Int)
}

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
      extension.CompactionPlugin(
        compaction.Strategy("rolling", fn(context, history) {
          use config <- result.try(load_config())
          prepare_view(config, context, history)
        }),
      ),
    ],
    initialise,
  )
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
  use folded <- result.try(lcm.stored_view(
    context.store,
    context.session,
    history,
  ))
  let carries_lcm = folded != history
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
        case recorded.status, carries_lcm {
          "compacted", True ->
            "durable transcript through stored LCM nodes, rolling summary, recent user recap, and verbatim tail"
          "compacted", False ->
            "durable transcript through rolling summary + recent user recap + verbatim tail"
          _, True ->
            "durable transcript through stored LCM nodes and verbatim tail; rolling observation attached"
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

fn state_decoder() {
  use summary <- decode.field(0, decode.string)
  use cutoff <- decode.field(1, decode.int)
  use source_hash <- decode.field(2, decode.string)
  decode.success(State(summary, cutoff, source_hash))
}

fn load_state(
  ledger: store.Store,
  session: String,
) -> Result(Option(State), String) {
  store.query(ledger, fn(db) {
    sqlight.query(
      "SELECT summary,cutoff_count,source_hash FROM rolling_compaction_state WHERE session=?",
      db,
      [sqlight.text(session)],
      state_decoder(),
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
  case window {
    None -> {
      // Without a window there is no threshold to compare, but a saved
      // projection is still the user's standing instruction: honor it.
      use saved <- result.try(load_state(ledger, session))
      let #(state, invalidated) = valid_state(saved, source, history)
      use _ <- result.try(case invalidated {
        True -> delete_state(ledger, session)
        False -> Ok(Nil)
      })
      let current = projection(state, history)
      let status = case state {
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
      use saved <- result.try(load_state(ledger, session))
      let #(state, invalidated) = valid_state(saved, source, history)
      use _ <- result.try(case invalidated {
        True -> delete_state(ledger, session)
        False -> Ok(Nil)
      })
      let current = projection(state, history)
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
          let status = case state {
            Some(_) -> "compacted"
            None -> "not_needed"
          }
          let source = case invalidated {
            True ->
              "estimated after source fingerprint changed; saved projection reset"
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
          let previous_cutoff = case state {
            Some(saved) -> saved.cutoff_count
            None -> 0
          }
          let tail_budget = case force {
            True ->
              int.min(capacity, compaction.estimate_inputs(history))
              * config.tail_percent
              / 100
            False -> capacity * config.tail_percent / 100
          }
          use cutoff <- result.try(legal_cutoff(history, tail_budget))
          use _ <- result.try(case cutoff > previous_cutoff {
            True -> Ok(Nil)
            False ->
              Error(
                "cannot compact further without splitting the newest conversation/tool unit",
              )
          })
          let newly_evicted =
            history
            |> list.drop(previous_cutoff)
            |> list.take(cutoff - previous_cutoff)
          let previous_summary = case state {
            Some(saved) -> Some(saved.summary)
            None -> None
          }
          use summary <- result.try(
            summarize(compaction.SummaryRequest(
              model,
              previous_summary,
              newly_evicted,
              int.min(2048, int.max(128, capacity / 10)),
            ))
            |> result.map(string.trim)
            |> result.try(fn(value) {
              case value == "" {
                True -> Error("summarizer returned an empty summary")
                False -> Ok(value)
              }
            }),
          )
          let next_state =
            State(
              summary,
              cutoff,
              source_fingerprint(source, list.take(history, cutoff)),
            )
          let next = projection(Some(next_state), history)
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

/// #(summary inputs, recap inputs, tail inputs, complete projection)
fn projection(
  state: Option(State),
  history: List(types.Input),
) -> #(
  List(types.Input),
  List(types.Input),
  List(types.Input),
  List(types.Input),
) {
  case state {
    None -> #([], [], history, history)
    Some(saved) -> {
      let summary = [
        types.User(
          "[older conversation summary; model-generated]\n"
          <> saved.summary
          <> "\n[end older conversation summary]",
        ),
      ]
      let recap = recap(history)
      let tail = list.drop(history, saved.cutoff_count)
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

fn valid_state(
  saved: Option(State),
  source: String,
  history: List(types.Input),
) -> #(Option(State), Bool) {
  case saved {
    None -> #(None, False)
    Some(state) -> {
      let valid =
        state.cutoff_count <= list.length(history)
        && source_fingerprint(source, list.take(history, state.cutoff_count))
        == state.source_hash
      case valid {
        True -> #(Some(state), False)
        False -> #(None, True)
      }
    }
  }
}

fn legal_cutoff(
  history: List(types.Input),
  tail_budget: Int,
) -> Result(Int, String) {
  let units = conversation_units(history)
  case units {
    [] -> Error("cannot compact an empty conversation")
    [_] ->
      Error("cannot compact without splitting the only conversation/tool unit")
    _ -> {
      let tail_items = choose_tail(list.reverse(units), tail_budget, 0, 0)
      let cutoff = list.length(history) - tail_items
      case cutoff > 0 {
        True -> Ok(cutoff)
        False -> Error("conversation tail already fits the configured target")
      }
    }
  }
}

fn choose_tail(
  newest_first: List(Unit),
  budget: Int,
  tokens: Int,
  items: Int,
) -> Int {
  case newest_first {
    [] -> items
    [Unit(unit, unit_tokens), ..rest] -> {
      let include = items == 0 || tokens + unit_tokens <= budget
      case include {
        True ->
          choose_tail(
            rest,
            budget,
            tokens + unit_tokens,
            items + list.length(unit),
          )
        False -> items
      }
    }
  }
}

fn conversation_units(history: List(types.Input)) -> List(Unit) {
  split_units(history, [], [])
}

fn split_units(
  remaining: List(types.Input),
  current: List(types.Input),
  complete: List(Unit),
) -> List(Unit) {
  case remaining {
    [] -> {
      let complete = case current {
        [] -> complete
        _ -> [make_unit(list.reverse(current)), ..complete]
      }
      list.reverse(complete)
    }
    [input, ..rest] -> {
      let begins_turn = case input {
        types.User(_) | types.UserImage(_, _) -> True
        _ -> False
      }
      case begins_turn && current != [] {
        True ->
          split_units(rest, [input], [
            make_unit(list.reverse(current)),
            ..complete
          ])
        False -> split_units(rest, [input, ..current], complete)
      }
    }
  }
}

fn make_unit(items: List(types.Input)) -> Unit {
  Unit(items, compaction.estimate_inputs(items))
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
            sqlight.int(state.cutoff_count),
            sqlight.text(state.source_hash),
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
  fingerprint(#(source, inputs))
}

@external(erlang, "albedo_rolling", "fingerprint")
fn fingerprint(value: a) -> String
