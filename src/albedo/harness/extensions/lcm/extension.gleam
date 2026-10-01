//// Lossless context management: source-backed summaries plus a verbatim tail.
//// All summary nodes are derived views over immutable transcript rows.

import albedo/daemon/conversation
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/harness/compaction
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/rolling/extension as rolling
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

type ModelUnit {
  ModelUnit(items: List(types.Input), tokens: Int)
}

fn default_config() -> Config {
  Config(None, 80, 25)
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
      harness_extension.CleanPlugin(graph.forget_session),
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
  use frontier <- result.try(case available {
    False -> Ok([])
    True -> graph.frontier(ledger, session)
  })
  case frontier {
    [] -> compaction.no_prior(history)
    _ -> {
      use covered <- result.try(graph.last_seq(ledger, session))
      use snapshot <- result.try(conversation.snapshot(ledger, session))
      use stats <- result.try(conversation.source_stats(
        ledger,
        snapshot,
        covered,
      ))
      Ok(split(frontier, history, stats, None, 0))
    }
  }
}

fn decoder() -> decode.Decoder(Config) {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field("triggerPercent", 80, decode.int)
  use tail <- decode.optional_field("tailPercent", 25, decode.int)
  decode.success(Config(capacity, trigger, tail))
}

fn validate(config: Config) -> Result(Config, String) {
  rolling.validate_window(
    "lcm",
    config.context_window_tokens,
    config.trigger_percent,
    config.tail_percent,
  )
  |> result.replace(config)
}

fn prepare(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  use snapshot <- result.try(conversation.snapshot(
    context.store,
    context.session,
  ))
  use covered <- result.try(graph.last_seq(context.store, context.session))
  use frontier <- result.try(graph.frontier(context.store, context.session))
  use stats <- result.try(conversation.source_stats(
    context.store,
    snapshot,
    covered,
  ))
  let window =
    rolling.effective_window(config.context_window_tokens, context, history)
  let tail_budget =
    option.map(window, fn(window) { window.tokens * config.tail_percent / 100 })
  let current = projection(frontier, history, stats, tail_budget, 1)
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
      use _ <- result.try(compaction.require(
        context.pinned_tokens < capacity,
        "context window is not large enough for pinned system, extension context, and tool schemas",
      ))
      case
        compaction.triggered(
          context.force,
          estimated,
          Some(capacity),
          config.trigger_percent,
        )
      {
        False ->
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
        True -> {
          let previous_frontier = frontier
          use latest_user <- result.try(option.to_result(
            stats.latest_user,
            "LCM needs a user message to retain as its tail",
          ))
          use eligible <- result.try(case covered + 1 < latest_user {
            False -> Ok([])
            True ->
              conversation.fold_sources(
                context.store,
                snapshot,
                covered + 1,
                latest_user - 1,
                [],
                fn(rows, item) { conversation.Continue([item, ..rows]) },
              )
          })
          let eligible = list.reverse(eligible)
          use _ <- result.try(compaction.require(
            eligible != [] || frontier != [],
            "cannot compact without an older complete conversation unit",
          ))
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
          use stats <- result.try(conversation.source_stats(
            context.store,
            snapshot,
            covered,
          ))
          use frontier <- result.try(condense_until_fit(
            context,
            frontier,
            history,
            stats,
            tail_budget,
            capacity,
            summary_limit,
            0,
          ))
          let next = projection(frontier, history, stats, tail_budget, 1)
          let next_estimated =
            context.pinned_tokens + compaction.estimate_inputs(next)
          use _ <- result.try(compaction.require(
            next_estimated < capacity || context.force,
            "LCM summaries and the newest conversation/tool unit do not fit the context window",
          ))
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
    Some(compaction.observation(
      "lcm",
      status,
      source,
      case frontier {
        [] -> "durable transcript without an LCM summary"
        _ ->
          "durable transcript through source-backed LCM nodes + verbatim tail"
      },
      config.trigger_percent,
      capacity,
      estimated,
      list.length(original),
      list.length(inputs),
    )),
    False,
  )
}

fn projection(
  frontier: List(graph.Node),
  history: List(types.Input),
  stats: conversation.SourceStats,
  tail_budget: Option(Int),
  minimum_tail_units: Int,
) -> List(types.Input) {
  let compaction.Prior(folds, rest) =
    split(frontier, history, stats, tail_budget, minimum_tail_units)
  list.append(folds, rest)
}

fn split(
  frontier: List(graph.Node),
  history: List(types.Input),
  stats: conversation.SourceStats,
  tail_budget: Option(Int),
  minimum_tail_units: Int,
) -> compaction.Prior {
  case frontier {
    [] -> compaction.Prior([], history)
    nodes -> {
      // An assistant or tool result can follow the cursor without a user row.
      // Retain its whole projected unit until live source references permit
      // a narrower cut.
      let minimum = case stats.uncovered {
        False -> minimum_tail_units
        True -> int.max(1, minimum_tail_units)
      }
      let tail =
        retain_tail(
          history,
          int.max(minimum, stats.uncovered_users),
          tail_budget,
        )
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
  let chunks = rolling.chunk_units(source_units(eligible), leaf_budget)
  use chunk <- list.try_map(chunks)
  case chunk {
    [] -> Error("cannot summarize an empty source chunk")
    [first, ..rest] -> {
      let last = list.fold(rest, first, fn(_, item) { item })
      let inputs = list.map(chunk, fn(item) { item.entry.input })
      use summary <- result.try(summarize_bounded(
        context,
        inputs,
        summary_limit,
      ))
      Ok(graph.Leaf(first.source.seq, last.source.seq, summary))
    }
  }
}

/// Source rows grouped into conversation units, each with its token cost.
fn source_units(
  sources: List(transcript.SourcedEntry),
) -> List(#(List(transcript.SourcedEntry), Int)) {
  compaction.split_starts(sources, fn(item) {
    compaction.is_user(item.entry.input)
  })
  |> list.map(fn(items) {
    #(
      items,
      items
        |> list.map(fn(item) { item.entry.input })
        |> compaction.estimate_inputs,
    )
  })
}

fn model_units(history: List(types.Input)) -> List(ModelUnit) {
  compaction.split_starts(history, compaction.is_user)
  |> list.map(fn(items) { ModelUnit(items, compaction.estimate_inputs(items)) })
}

fn retain_tail(
  history: List(types.Input),
  required_units: Int,
  budget: Option(Int),
) -> List(types.Input) {
  model_units(history)
  |> list.reverse
  |> compaction.keep_tail(required_units, budget, fn(unit) { unit.tokens })
  |> list.flat_map(fn(unit) { unit.items })
}

fn condense_until_fit(
  context: compaction.Context,
  frontier: List(graph.Node),
  history: List(types.Input),
  stats: conversation.SourceStats,
  tail_budget: Option(Int),
  capacity: Int,
  summary_limit: Int,
  attempts: Int,
) -> Result(List(graph.Node), String) {
  let view = projection(frontier, history, stats, tail_budget, 1)
  let estimated = context.pinned_tokens + compaction.estimate_inputs(view)
  case estimated < capacity || attempts >= 16, frontier {
    False, [_, _, ..] -> {
      let group = list.take(frontier, 4)
      let input = list.map(group, node_input)
      use summary <- result.try(summarize_bounded(context, input, summary_limit))
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
        stats,
        tail_budget,
        capacity,
        summary_limit,
        attempts + 1,
      )
    }
    _, _ -> Ok(frontier)
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
  use first <- result.try(attempt_summary(context, inputs, limit))
  case fits_summary(first, original, limit) {
    True -> Ok(first)
    False ->
      attempt_summary(context, inputs, int.max(32, limit / 3))
      |> result.map(fn(second) {
        case fits_summary(second, original, limit) {
          True -> second
          False -> "Summary exceeded its source; inspect the linked rows."
        }
      })
  }
}

/// One summarizer call: trimmed, non-empty, bounded by `limit` output tokens.
fn attempt_summary(
  context: compaction.Context,
  inputs: List(types.Input),
  limit: Int,
) -> Result(String, String) {
  use summary <- result.try(
    context.summarize(compaction.SummaryRequest(
      context.model,
      None,
      inputs,
      limit,
      compaction.summary_instructions,
    )),
  )
  let summary = string.trim(summary)
  use _ <- result.try(compaction.require(
    summary != "",
    "LCM summarizer returned an empty summary",
  ))
  Ok(summary)
}

fn fits_summary(summary: String, original: Int, limit: Int) -> Bool {
  let tokens = compaction.estimate_inputs([types.User(summary)])
  tokens < original && tokens <= limit
}
