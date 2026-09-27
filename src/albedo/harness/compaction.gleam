//// Optional request-history projection, not a transcript rewrite.

import albedo/daemon/store
import albedo/harness/extensions/python/kernel
import albedo/openai_api/types
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type SummaryRequest {
  SummaryRequest(
    model: String,
    previous: Option(String),
    evicted: List(types.Input),
    max_output_tokens: Int,
  )
}

/// A context window a catalog or configuration actually reported, with the
/// provenance a strategy must show rather than an assumed model limit.
pub type Capacity {
  Capacity(tokens: Int, source: String)
}

pub type Context {
  Context(
    store: store.Store,
    session: String,
    kernel: kernel.Kernel,
    model: String,
    source: String,
    pinned_tokens: Int,
    capacity: Option(Capacity),
    force: Bool,
    summarize: fn(SummaryRequest) -> Result(String, String),
    /// History with folds stored by other strategies applied; see `Prior`.
    prior: fn(List(types.Input)) -> Result(Prior, String),
    /// Who reads the request, when a models catalog knows the model.
    reader: Option(Reader),
  )
}

/// The provider carrying a request and the input kinds its model accepts, as
/// a models catalog reported them. An empty `input_modalities` means the
/// catalog did not say.
pub type Reader {
  Reader(provider: String, input_modalities: List(String))
}

/// Whether the model reads image input: `None` when no catalog says.
pub fn reads_images(context: Context) -> Option(Bool) {
  case context.reader {
    Some(Reader(_, [_, ..] as modalities)) ->
      Some(list.contains(modalities, "image"))
    _ -> None
  }
}

/// Chronological history split at the point stored folds cover. `folds` are
/// summaries another strategy already wrote, oldest first; `rest` is the
/// history they do not cover. Without stored folds, `folds` is empty and
/// `rest` is the history unchanged.
pub type Prior {
  Prior(folds: List(types.Input), rest: List(types.Input))
}

/// Supplies stored folds for one session's history. The extension that owns
/// the storage registers it, so strategies need not import each other.
pub type Folds {
  Folds(
    name: String,
    /// The strategy that writes these folds. It reads its own state directly,
    /// so the runtime leaves this provider out while that strategy is active.
    owner: String,
    apply: fn(store.Store, String, List(types.Input)) -> Result(Prior, String),
  )
}

/// The history a strategy sees when no fold provider is enabled.
pub fn no_prior(history: List(types.Input)) -> Result(Prior, String) {
  Ok(Prior([], history))
}

/// Applies providers in order; each later one sees only what earlier ones
/// left uncovered.
pub fn compose_prior(
  providers: List(Folds),
  ledger: store.Store,
  session: String,
) -> fn(List(types.Input)) -> Result(Prior, String) {
  fn(history) {
    list.try_fold(providers, Prior([], history), fn(prior, provider) {
      use next <- result.try(provider.apply(ledger, session, prior.rest))
      Ok(Prior(list.append(prior.folds, next.folds), next.rest))
    })
  }
}

/// What a strategy prepared for one request. The observation describes this
/// exact preparation, so inspectors do not need to query strategy-owned state.
pub type Prepared {
  Prepared(inputs: List(types.Input), observation: Option(Observation))
}

/// Strategy-neutral facts for the request inspector. A strategy may add more
/// detail to `source` and `history_source` without changing the inspector.
pub type Observation {
  Observation(
    strategy: String,
    status: String,
    source: String,
    history_source: String,
    trigger_free_percent: Option(Int),
    input_limit_tokens: Option(Int),
    estimated_input_tokens: Option(Int),
    estimate_method: Option(String),
    before_items: Option(Int),
    after_items: Option(Int),
  )
}

/// Receives chronological history before each model request. Implementations
/// own their summaries/state and must preserve valid tool call/result pairs.
/// Failure stops the turn; the full durable transcript is never replaced.
pub type Strategy {
  Strategy(
    name: String,
    prepare: fn(Context, List(types.Input)) -> Result(Prepared, String),
  )
}

/// A deliberately approximate request-size estimate. It is used only when a
/// provider has not supplied a tokenizer for the current request.
pub fn estimate_text(text: String) -> Int {
  { string.byte_size(text) + 3 } / 4
}

pub fn input_bytes(input: types.Input) -> Int {
  case input {
    types.User(text) | types.Assistant(text) -> string.byte_size(text)
    types.UserImage(text, image) -> {
      string.byte_size(text) + types.image_size(image)
    }
    types.ToolOutput(id, output, images) ->
      string.byte_size(id)
      + string.byte_size(output)
      + list.fold(images, 0, fn(total, image) {
        total + types.image_size(image)
      })
    types.Replay(item) ->
      types.replay_json(item) |> json.to_string |> string.byte_size
  }
}

pub fn inputs_bytes(inputs: List(types.Input)) -> Int {
  inputs |> list.fold(0, fn(total, input) { total + input_bytes(input) })
}

pub fn estimate_input(input: types.Input) -> Int {
  // Covers request framing, roles, and content-part keys without pretending
  // to be an exact provider tokenizer. Image payload bytes affect transport
  // size, not vision tokens, so image cost is estimated from dimensions.
  case input {
    types.UserImage(text, image) ->
      estimate_text(text) + estimate_image(image) + 20
    types.ToolOutput(id, output, [_, ..] as images) ->
      estimate_text(id <> output)
      + list.fold(images, 0, fn(total, image) {
        total + estimate_image(image) + 20
      })
      + 12
    _ -> { input_bytes(input) + 3 } / 4 + 12
  }
}

fn estimate_image(image: types.Image) -> Int {
  let #(_, width, height, _) = types.image_meta(image)
  image_tokens(width, height)
}

/// Provider-neutral approximation based on 512px vision tiles. Providers may
/// tokenize images differently; this is only the compaction trigger signal.
pub fn image_tokens(width: Int, height: Int) -> Int {
  85 + 170 * ceiling_div(width, 512) * ceiling_div(height, 512)
}

fn ceiling_div(value: Int, divisor: Int) -> Int {
  { value + divisor - 1 } / divisor
}

pub fn estimate_inputs(inputs: List(types.Input)) -> Int {
  inputs |> list.fold(0, fn(total, input) { total + estimate_input(input) })
}

pub fn estimate_tools(tools: List(types.Tool)) -> Int {
  tools
  |> list.fold(0, fn(total, tool) {
    total
    + estimate_text(tool.name)
    + estimate_text(tool.description)
    + estimate_text(json.to_string(tool.parameters))
    + 20
  })
}

pub fn estimate_pinned(instructions: String, tools: List(types.Tool)) -> Int {
  16 + estimate_text(instructions) + estimate_tools(tools)
}

/// Where a saved compaction splits history: after `users` user messages. Each
/// provider projection keeps user inputs verbatim and in order, merging or
/// dropping only assistant output, so a cut counted in user messages survives
/// a model or provider switch where an item count would not. The fingerprint
/// covers those user messages, so a rewritten transcript invalidates the cut.
pub type Cut {
  Cut(users: Int, fingerprint: String)
}

/// The cut that evicts exactly `prefix`, which must end before a user message.
pub fn cut_of(prefix: List(types.Input)) -> Cut {
  let users = list.filter(prefix, is_user)
  Cut(list.length(users), fingerprint(users))
}

/// Splits history at a saved cut: the evicted prefix and the rest, which
/// starts at a user message. `Error` when this history no longer matches.
pub fn resume(
  history: List(types.Input),
  cut: Cut,
) -> Result(#(List(types.Input), List(types.Input)), Nil) {
  use #(prefix, rest) <- result.try(split_users(history, cut.users, 0, []))
  case cut_of(prefix) == cut {
    True -> Ok(#(prefix, rest))
    False -> Error(Nil)
  }
}

fn split_users(
  history: List(types.Input),
  users: Int,
  seen: Int,
  prefix: List(types.Input),
) -> Result(#(List(types.Input), List(types.Input)), Nil) {
  case history {
    [] -> Error(Nil)
    [input, ..rest] ->
      case is_user(input), seen == users {
        True, True -> Ok(#(list.reverse(prefix), history))
        True, False -> split_users(rest, users, seen + 1, [input, ..prefix])
        False, _ -> split_users(rest, users, seen, [input, ..prefix])
      }
  }
}

/// Splits history into what compaction may evict and a verbatim tail of the
/// newest whole units (a user message and everything answering it) within
/// `budget` estimated tokens, never fewer than the newest unit, so a tool
/// result never loses its call. Evicts nothing from a single unit.
pub fn split_tail(
  history: List(types.Input),
  budget: Int,
) -> #(List(types.Input), List(types.Input)) {
  let kept = keep_units(list.reverse(units(history, [], [])), budget, 0, 0)
  list.split(history, list.length(history) - kept)
}

fn keep_units(
  newest_first: List(List(types.Input)),
  budget: Int,
  tokens: Int,
  items: Int,
) -> Int {
  case newest_first {
    [] -> items
    [unit, ..rest] -> {
      let spent = tokens + estimate_inputs(unit)
      case items == 0 || spent <= budget {
        True -> keep_units(rest, budget, spent, items + list.length(unit))
        False -> items
      }
    }
  }
}

fn units(
  remaining: List(types.Input),
  current: List(types.Input),
  complete: List(List(types.Input)),
) -> List(List(types.Input)) {
  case remaining, current {
    [], [] -> list.reverse(complete)
    [], _ -> list.reverse([list.reverse(current), ..complete])
    [input, ..rest], [_, ..] ->
      case is_user(input) {
        True -> units(rest, [input], [list.reverse(current), ..complete])
        False -> units(rest, [input, ..current], complete)
      }
    [input, ..rest], [] -> units(rest, [input], complete)
  }
}

pub fn is_user(input: types.Input) -> Bool {
  case input {
    types.User(_) | types.UserImage(_, _) -> True
    _ -> False
  }
}

@external(erlang, "albedo_compaction", "fingerprint")
pub fn fingerprint(value: a) -> String
