//// Lossless context management: source-backed summaries plus a verbatim tail.
//// All summary nodes are derived views over immutable transcript rows.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/harness/compaction
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/lcm/graph
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const leaf_budget = 6000

const summary_tokens = 768

pub type Config {
  Config(
    context_window_tokens: Option(Int),
    trigger_percent: Int,
    tail_percent: Int,
  )
}

type SourceUnit {
  SourceUnit(items: List(transcript.SourcedEntry), tokens: Int)
}

type ModelUnit {
  ModelUnit(items: List(types.Input), tokens: Int)
}

pub fn default_config() -> Config {
  Config(None, 90, 25)
}

pub fn configured_extension(config: Config) -> harness_extension.Extension {
  bundle(fn() { validate(config) })
}

pub fn extension() -> harness_extension.Extension {
  bundle(fn() {
    use config <- result.try(settings.load("lcm", decoder(), default_config()))
    validate(config)
  })
}

fn bundle(
  resolve: fn() -> Result(Config, String),
) -> harness_extension.Extension {
  harness_extension.Extension(
    "lcm",
    "Source-backed hierarchical summaries with bounded history retrieval",
    ["lcm-memory"],
    [
      harness_extension.CompactionPlugin(
        compaction.Strategy("lcm", fn(context, history) {
          use config <- result.try(resolve())
          prepare(config, context, history)
        }),
      ),
    ],
    graph.initialise,
  )
}

/// Stored LCM folds for another strategy's source history after a strategy
/// change. The graph stays fixed while LCM is inactive, so a strategy's source
/// hashes continue to refer to the same folded prefix as new turns arrive.
pub fn stored_prior(
  ledger: store.Store,
  session: String,
  history: List(types.Input),
) -> Result(compaction.Prior, String) {
  use available <- result.try(graph.storage_available(ledger))
  case available {
    False -> compaction.no_prior(history)
    True -> {
      use frontier <- result.try(graph.frontier(ledger, session))
      case frontier {
        [] -> compaction.no_prior(history)
        _ -> {
          use covered <- result.try(graph.last_seq(ledger, session))
          use sources <- result.try(conversation.load_sources(ledger, session))
          Ok(split(frontier, history, sources, covered, None, 0))
        }
      }
    }
  }
}

fn decoder() {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field("triggerPercent", 90, decode.int)
  use tail <- decode.optional_field("tailPercent", 25, decode.int)
  decode.success(Config(capacity, trigger, tail))
}

fn validate(config: Config) -> Result(Config, String) {
  case config.context_window_tokens {
    Some(value) if value <= 0 ->
      Error("lcm contextWindowTokens must be positive")
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
            "lcm percentages must satisfy 0 < tailPercent < triggerPercent < 100",
          )
      }
  }
}

fn prepare(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  use sources <- result.try(conversation.load_sources(
    context.store,
    context.session,
  ))
  use covered <- result.try(graph.last_seq(context.store, context.session))
  use frontier <- result.try(graph.frontier(context.store, context.session))
  let window = case
    config.context_window_tokens,
    context.capacity,
    context.force
  {
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
  let tail_budget = case window {
    Some(compaction.Capacity(tokens: tokens, ..)) ->
      Some(tokens * config.tail_percent / 100)
    None -> None
  }
  let current = projection(frontier, history, sources, covered, tail_budget, 1)
  let estimated = context.pinned_tokens + compaction.estimate_inputs(current)
  case window {
    None ->
      Ok(prepared(
        current,
        frontier,
        "unknown",
        "estimated; no configured or catalogued context window",
        None,
        estimated,
        config,
        history,
      ))
    Some(compaction.Capacity(tokens: capacity, source: capacity_source)) -> {
      use _ <- result.try(case context.pinned_tokens < capacity {
        True -> Ok(Nil)
        False ->
          Error(
            "context window is not large enough for pinned system, extension context, and tool schemas",
          )
      })
      case
        !context.force && estimated * 100 < capacity * config.trigger_percent
      {
        True ->
          Ok(prepared(
            current,
            frontier,
            case frontier {
              [] -> "not_needed"
              _ -> "compacted"
            },
            "estimated from current request projection; window from "
              <> capacity_source,
            Some(capacity),
            estimated,
            config,
            history,
          ))
        False -> {
          let previous_frontier = frontier
          use latest_user <- result.try(latest_user_seq(sources))
          let eligible =
            list.filter(sources, fn(item) {
              item.source.seq > covered && item.source.seq < latest_user
            })
          use _ <- result.try(case eligible, frontier {
            [], [] ->
              Error(
                "cannot compact without an older complete conversation unit",
              )
            _, _ -> Ok(Nil)
          })
          let summary_limit =
            int.min(
              summary_tokens,
              int.max(32, { capacity - context.pinned_tokens } / 4),
            )
          use leaves <- result.try(summarize_leaves(
            context,
            eligible,
            summary_limit,
          ))
          use _ <- result.try(graph.save_leaves(
            context.store,
            context.session,
            leaves,
          ))
          use frontier <- result.try(graph.frontier(
            context.store,
            context.session,
          ))
          use covered <- result.try(graph.last_seq(
            context.store,
            context.session,
          ))
          use frontier <- result.try(condense_until_fit(
            context,
            frontier,
            history,
            sources,
            covered,
            tail_budget,
            capacity,
            summary_limit,
            0,
          ))
          let next =
            projection(frontier, history, sources, covered, tail_budget, 1)
          let next_estimated =
            context.pinned_tokens + compaction.estimate_inputs(next)
          use _ <- result.try(case next_estimated < capacity || context.force {
            True -> Ok(Nil)
            False ->
              Error(
                "LCM summaries and the newest conversation/tool unit do not fit the context window",
              )
          })
          let prepared =
            prepared(
              next,
              frontier,
              "compacted",
              "estimated from source-backed summary nodes; window from "
                <> capacity_source,
              Some(capacity),
              next_estimated,
              config,
              history,
            )
          Ok(
            compaction.Prepared(
              ..prepared,
              compacted: frontier != previous_frontier,
            ),
          )
        }
      }
    }
  }
}

fn prepared(
  inputs: List(types.Input),
  frontier: List(graph.Node),
  status: String,
  source: String,
  capacity: Option(Int),
  estimated: Int,
  config: Config,
  original: List(types.Input),
) -> compaction.Prepared {
  compaction.Prepared(
    inputs,
    Some(compaction.Observation(
      "lcm",
      status,
      source,
      case frontier {
        [] -> "durable transcript without an LCM summary"
        _ ->
          "durable transcript through source-backed LCM nodes + verbatim tail"
      },
      Some(100 - config.trigger_percent),
      capacity,
      Some(estimated),
      Some("local byte-based estimate; not provider token usage"),
      Some(list.length(original)),
      Some(list.length(inputs)),
    )),
    False,
  )
}

fn latest_user_seq(
  sources: List(transcript.SourcedEntry),
) -> Result(Int, String) {
  sources
  |> list.reverse
  |> list.find(fn(item) {
    case item.entry.input {
      types.User(_) | types.UserImage(_, _) -> True
      _ -> False
    }
  })
  |> result.map(fn(item) { item.source.seq })
  |> result.map_error(fn(_) { "LCM needs a user message to retain as its tail" })
}

fn projection(
  frontier: List(graph.Node),
  history: List(types.Input),
  sources: List(transcript.SourcedEntry),
  covered: Int,
  tail_budget: Option(Int),
  minimum_tail_units: Int,
) -> List(types.Input) {
  let compaction.Prior(folds, rest) =
    split(frontier, history, sources, covered, tail_budget, minimum_tail_units)
  list.append(folds, rest)
}

fn split(
  frontier: List(graph.Node),
  history: List(types.Input),
  sources: List(transcript.SourcedEntry),
  covered: Int,
  tail_budget: Option(Int),
  minimum_tail_units: Int,
) -> compaction.Prior {
  case frontier {
    [] -> compaction.Prior([], history)
    nodes -> {
      let unsummarized =
        list.filter(sources, fn(item) { item.source.seq > covered })
      let unsummarized_users =
        unsummarized
        |> list.filter(fn(item) {
          case item.entry.input {
            types.User(_) | types.UserImage(_, _) -> True
            _ -> False
          }
        })
        |> list.length
      // An assistant or tool result can follow the cursor without a user row.
      // Retain its whole projected unit until live source references permit
      // a narrower cut.
      let minimum = case unsummarized {
        [] -> minimum_tail_units
        _ -> int.max(1, minimum_tail_units)
      }
      let tail =
        retain_tail(history, int.max(minimum, unsummarized_users), tail_budget)
      compaction.Prior(list.map(nodes, node_input), tail)
    }
  }
}

fn node_input(node: graph.Node) -> types.Input {
  types.User(
    "[LCM summary node #"
    <> int.to_string(node.id)
    <> "; durable source rows "
    <> int.to_string(node.first_seq)
    <> ".."
    <> int.to_string(node.last_seq)
    <> "; use lcm_grep/lcm_describe/lcm_expand to recover details]\n"
    <> node.summary
    <> "\n[end LCM node #"
    <> int.to_string(node.id)
    <> "]",
  )
}

fn summarize_leaves(
  context: compaction.Context,
  eligible: List(transcript.SourcedEntry),
  summary_limit: Int,
) -> Result(List(graph.Leaf), String) {
  let units = source_units(eligible)
  let chunks = chunk_units(units, [], 0, [])
  list.try_map(chunks, fn(chunk) {
    let assert [first, ..] = chunk
    let assert Ok(last) = list.last(chunk)
    let inputs = list.map(chunk, fn(item) { item.entry.input })
    use summary <- result.try(summarize_bounded(context, inputs, summary_limit))
    Ok(graph.Leaf(first.source.seq, last.source.seq, summary))
  })
}

fn source_units(sources: List(transcript.SourcedEntry)) -> List(SourceUnit) {
  split_source_units(sources, [], [])
}

fn split_source_units(
  remaining: List(transcript.SourcedEntry),
  current: List(transcript.SourcedEntry),
  complete: List(SourceUnit),
) -> List(SourceUnit) {
  case remaining {
    [] ->
      case current {
        [] -> list.reverse(complete)
        _ -> list.reverse([make_source_unit(list.reverse(current)), ..complete])
      }
    [item, ..rest] -> {
      let starts = case item.entry.input {
        types.User(_) | types.UserImage(_, _) -> True
        _ -> False
      }
      case starts && current != [] {
        True ->
          split_source_units(rest, [item], [
            make_source_unit(list.reverse(current)),
            ..complete
          ])
        False -> split_source_units(rest, [item, ..current], complete)
      }
    }
  }
}

fn make_source_unit(items: List(transcript.SourcedEntry)) -> SourceUnit {
  SourceUnit(
    items,
    items
      |> list.map(fn(item) { item.entry.input })
      |> compaction.estimate_inputs,
  )
}

fn chunk_units(
  remaining: List(SourceUnit),
  current: List(transcript.SourcedEntry),
  tokens: Int,
  complete: List(List(transcript.SourcedEntry)),
) -> List(List(transcript.SourcedEntry)) {
  case remaining {
    [] ->
      case current {
        [] -> list.reverse(complete)
        _ -> list.reverse([current, ..complete])
      }
    [unit, ..rest] ->
      case current != [] && tokens + unit.tokens > leaf_budget {
        True ->
          chunk_units(rest, unit.items, unit.tokens, [current, ..complete])
        False ->
          chunk_units(
            rest,
            list.append(current, unit.items),
            tokens + unit.tokens,
            complete,
          )
      }
  }
}

fn model_units(history: List(types.Input)) -> List(ModelUnit) {
  split_model_units(history, [], [])
}

fn split_model_units(
  remaining: List(types.Input),
  current: List(types.Input),
  complete: List(ModelUnit),
) -> List(ModelUnit) {
  case remaining {
    [] ->
      case current {
        [] -> list.reverse(complete)
        _ -> list.reverse([make_model_unit(list.reverse(current)), ..complete])
      }
    [input, ..rest] -> {
      let starts = case input {
        types.User(_) | types.UserImage(_, _) -> True
        _ -> False
      }
      case starts && current != [] {
        True ->
          split_model_units(rest, [input], [
            make_model_unit(list.reverse(current)),
            ..complete
          ])
        False -> split_model_units(rest, [input, ..current], complete)
      }
    }
  }
}

fn make_model_unit(items: List(types.Input)) -> ModelUnit {
  ModelUnit(items, compaction.estimate_inputs(items))
}

fn retain_tail(
  history: List(types.Input),
  required_units: Int,
  budget: Option(Int),
) -> List(types.Input) {
  model_units(history)
  |> list.reverse
  |> take_tail(required_units, budget, 0, 0, [])
  |> list.flatten
}

fn take_tail(
  newest_first: List(ModelUnit),
  required: Int,
  budget: Option(Int),
  kept: Int,
  tokens: Int,
  selected: List(List(types.Input)),
) -> List(List(types.Input)) {
  case newest_first {
    [] -> selected
    [unit, ..rest] -> {
      let within_budget = case budget {
        Some(limit) -> tokens + unit.tokens <= limit
        None -> False
      }
      case kept < required || within_budget {
        True ->
          take_tail(rest, required, budget, kept + 1, tokens + unit.tokens, [
            unit.items,
            ..selected
          ])
        False -> selected
      }
    }
  }
}

fn condense_until_fit(
  context: compaction.Context,
  frontier: List(graph.Node),
  history: List(types.Input),
  sources: List(transcript.SourcedEntry),
  covered: Int,
  tail_budget: Option(Int),
  capacity: Int,
  summary_limit: Int,
  attempts: Int,
) -> Result(List(graph.Node), String) {
  let view = projection(frontier, history, sources, covered, tail_budget, 1)
  let estimated = context.pinned_tokens + compaction.estimate_inputs(view)
  case estimated < capacity || attempts >= 16 {
    True -> Ok(frontier)
    False ->
      case frontier {
        [_, _, ..] -> {
          let group = list.take(frontier, 4)
          let input =
            group
            |> list.map(node_input)
          use summary <- result.try(summarize_bounded(
            context,
            input,
            summary_limit,
          ))
          use _ <- result.try(graph.save_parent(
            context.store,
            context.session,
            group,
            summary,
          ))
          use next <- result.try(graph.frontier(context.store, context.session))
          condense_until_fit(
            context,
            next,
            history,
            sources,
            covered,
            tail_budget,
            capacity,
            summary_limit,
            attempts + 1,
          )
        }
        _ -> Ok(frontier)
      }
  }
}

/// A provider can return a summary longer than its source. Retry with a
/// smaller output cap, then keep a short navigable pointer if both grow.
/// Source rows and child nodes remain intact in every case.
fn summarize_bounded(
  context: compaction.Context,
  inputs: List(types.Input),
  limit: Int,
) -> Result(String, String) {
  let original = compaction.estimate_inputs(inputs)
  use first <- result.try(
    context.summarize(compaction.SummaryRequest(
      context.model,
      None,
      inputs,
      limit,
    )),
  )
  let first = string.trim(first)
  use _ <- result.try(case first != "" {
    True -> Ok(Nil)
    False -> Error("LCM summarizer returned an empty summary")
  })
  case
    compaction.estimate_inputs([types.User(first)]) < original
    && compaction.estimate_inputs([types.User(first)]) <= limit
  {
    True -> Ok(first)
    False -> {
      use second <- result.try(
        context.summarize(compaction.SummaryRequest(
          context.model,
          None,
          inputs,
          int.max(32, limit / 3),
        )),
      )
      let second = string.trim(second)
      use _ <- result.try(case second != "" {
        True -> Ok(Nil)
        False -> Error("LCM summarizer returned an empty summary")
      })
      case
        compaction.estimate_inputs([types.User(second)]) < original
        && compaction.estimate_inputs([types.User(second)]) <= limit
      {
        True -> Ok(second)
        False -> Ok("Summary exceeded its source; inspect the linked rows.")
      }
    }
  }
}
