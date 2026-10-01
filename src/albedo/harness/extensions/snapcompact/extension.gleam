//// Compaction that archives discarded history as rendered bitmap frames the
//// vision stack reads directly, instead of a lossy summary. Frames are X11
//// 8x13 pixel-font text through the local albedo-render binary, cached in
//// `snapcompact_frames` keyed by geometry and content, so re-preparing a
//// request re-renders nothing. Frames assume the model accepts image input;
//// disable via settings for text-only models.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/snapcompact/transcript
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const default_trigger_percent = 90

/// Kept verbatim after a compaction: a small tail leaves the window to the
/// archive and to new turns.
const default_tail_percent = 10

/// The archive's share of the window, at the estimated cost of a full frame.
const default_archive_percent = 20

/// Frames the archive keeps at most. oh-my-pi sizes this to ~400k tokens of
/// high-res frames under Anthropic's 100-image request cap.
const max_frames = 80

/// Inline base64 frame data one request may carry: gateways fail opaquely
/// once a request carries a few MB. A frame is about 50 KB. The Claude
/// provider uploads images through the files API, so it is exempt.
const frame_data_budget = 3_000_000

const frame_data_estimate = 50_000

/// Characters per archive page handed to another strategy as a text fold.
const fold_page_cells = 6000

const result_chars = 1600

const message_chars = 8000

const call_args_chars = 1500

/// Bound on the arguments JSON before it is decoded for formatting.
const args_bytes = 8192

/// Cached frames unreferenced this long are pruned at startup.
const frame_retention_ms = 2_592_000_000

const frame_schema = "CREATE TABLE IF NOT EXISTS snapcompact_frames(key TEXT PRIMARY KEY,hash TEXT NOT NULL,data TEXT NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,bytes INTEGER NOT NULL,created_at INTEGER NOT NULL);"

const archive_schema = "CREATE TABLE IF NOT EXISTS snapcompact_archive(session TEXT PRIMARY KEY,users INTEGER NOT NULL CHECK(users >= 0),fingerprint TEXT NOT NULL,text TEXT NOT NULL,dropped INTEGER NOT NULL CHECK(dropped >= 0));"

const truncation_note = "The conversation above this message was truncated; its earlier history could not be archived."

const description = "History archived as rendered bitmap frames the vision stack reads directly"

/// U+2588 FULL BLOCK: the cell that stands for a newline in the archive.
const newline_cell = "\u{2588}"

@external(erlang, "albedo_snapcompact", "render_frames")
fn render_frames(
  chunks: List(String),
  advance: Int,
  pitch: Int,
  width: Int,
) -> Result(List(#(Int, Int, Int, String)), String)

/// One frame rendered now, for tests: `Ok(#(width, height, base64))`.
pub fn render_frame_test(
  text: String,
  advance: Int,
  pitch: Int,
  width: Int,
) -> Result(#(Int, Int, String), String) {
  render_frames([text], advance, pitch, width)
  |> result.map(fn(frames) {
    case frames {
      [#(width, height, _, data)] -> #(width, height, data)
      _ -> #(0, 0, "")
    }
  })
}

@external(erlang, "albedo_snapcompact", "paginate")
fn paginate_ffi(text: String, per_frame: Int) -> List(String)

@external(erlang, "albedo_snapcompact", "now_ms")
fn now_ms() -> Int

@external(erlang, "albedo_snapcompact", "sha256")
fn sha256(data: String) -> String

@external(erlang, "albedo_snapcompact", "normalize")
fn normalize_ansi(text: String) -> String

@external(erlang, "albedo_snapcompact", "format_args")
fn format_args(arguments: String) -> String

pub type Config {
  Config(
    context_window_tokens: Option(Int),
    trigger_percent: Int,
    tail_percent: Int,
    archive_percent: Int,
    max_frames: Option(Int),
    enabled: Bool,
  )
}

pub type Shape {
  Shape(advance: Int, pitch: Int, width: Int, rows: Int)
}

/// The saved archive: the normalized text of everything before `cut`, kept
/// within the frame budget, and how many characters that budget has dropped.
/// Frames are re-derived from the text, so a model switch re-renders it in
/// the new stack's shape instead of discarding it.
type Archive {
  Archive(cut: compaction.Cut, text: String, dropped: Int)
}

type FrameRow {
  FrameRow(key: String, hash: String, width: Int, height: Int, bytes: Int)
}

fn default_config() -> Config {
  Config(
    None,
    default_trigger_percent,
    default_tail_percent,
    default_archive_percent,
    None,
    True,
  )
}

fn config_decoder() -> decode.Decoder(Config) {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field(
    "triggerPercent",
    default_trigger_percent,
    decode.int,
  )
  use tail <- decode.optional_field(
    "tailPercent",
    default_tail_percent,
    decode.int,
  )
  use archive <- decode.optional_field(
    "archivePercent",
    default_archive_percent,
    decode.int,
  )
  use frames <- decode.optional_field(
    "maxFrames",
    None,
    decode.optional(decode.int),
  )
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  decode.success(Config(capacity, trigger, tail, archive, frames, enabled))
}

fn validated(loaded: Result(Config, String)) -> Result(Config, String) {
  use config <- result.try(loaded)
  validate_config(config)
}

fn load_config() -> Result(Config, String) {
  validated(settings.load("snapcompact", config_decoder(), default_config()))
}

fn validate_config(config: Config) -> Result(Config, String) {
  case config.context_window_tokens, config.max_frames {
    Some(capacity), _ if capacity <= 0 ->
      Error("snapcompact contextWindowTokens must be positive")
    _, Some(frames) if frames <= 0 ->
      Error("snapcompact maxFrames must be positive")
    _, _ ->
      case
        config.trigger_percent > 0
        && config.trigger_percent < 100
        && config.tail_percent > 0
        && config.tail_percent < config.trigger_percent
        && config.archive_percent > 0
        && config.archive_percent < 100
      {
        True -> Ok(config)
        False ->
          Error(
            "snapcompact percentages must satisfy 0 < tailPercent < triggerPercent < 100 and 0 < archivePercent < 100",
          )
      }
  }
}

/// Registration only gates plugin presence on configuration; the strategy
/// reloads settings per compaction so edits apply without a daemon restart.
pub fn extension() -> extension.Extension {
  extension.Extension(
    "snapcompact",
    description,
    ["snapcompact-memory"],
    compaction_plugins(),
    initialise,
  )
}

/// The saved archive and the transcript tools stay available after a switch
/// to another strategy, which reads the archive as text folds.
pub fn memory() -> extension.Extension {
  extension.Extension(
    "snapcompact-memory",
    "Read the snapcompact archive and the transcript rows it covers",
    [],
    [
      extension.ToolPlugin(
        "Earlier conversation may be archived as rendered frames or serialized text. transcript_grep finds a literal term in this session's full durable transcript; transcript_read reads bounded pages of its original rows.",
        transcript.definitions(),
        [],
        [],
      ),
      extension.FoldPlugin(compaction.Folds(
        "snapcompact",
        "snapcompact",
        stored_prior,
      )),
    ],
    initialise,
  )
}

/// The archive as folds for another strategy: readable text pages, oldest
/// first, and the history after the archive's cut.
fn stored_prior(
  ledger: store.Store,
  session: String,
  history: List(types.Input),
) -> Result(compaction.Prior, String) {
  use saved <- result.try(load_archive(ledger, session))
  case
    option.then(saved, fn(archive) {
      compaction.resume(history, archive.cut)
      |> result.map(fn(split) { #(archive, split.1) })
      |> option.from_result
    })
  {
    Some(#(archive, rest)) -> {
      let pages = paginate_ffi(archive.text, fold_page_cells)
      let total = int.to_string(list.length(pages))
      let folds =
        list.index_map(pages, fn(page, index) {
          types.User(
            "[snapcompact archive page "
            <> int.to_string(index + 1)
            <> " of "
            <> total
            <> "; earlier conversation, serialized; transcript_grep and transcript_read reach the original rows]\n"
            <> string.replace(page, newline_cell, "\n"),
          )
        })
      Ok(compaction.Prior(folds, rest))
    }
    _ -> compaction.no_prior(history)
  }
}

fn compaction_plugins() -> List(extension.Plugin) {
  case load_config() {
    Ok(_) -> [
      extension.CompactionPlugin(strategy_with(load_config)),
    ]
    Error(_) -> []
  }
}

/// Snapcompact under fixed settings, for embedders and tests.
pub fn configured_extension(config: Config) -> extension.Extension {
  extension.Extension(
    "snapcompact",
    description,
    [],
    [extension.CompactionPlugin(strategy_with(fn() { Ok(config) }))],
    initialise,
  )
}

/// The strategy under the settings `resolve` answers per compaction.
/// The strategy under the settings `resolve` answers per compaction.
fn strategy_with(
  resolve: fn() -> Result(Config, String),
) -> compaction.Strategy {
  compaction.Strategy("snapcompact", fn(context, history) {
    use valid <- result.try(result.try(resolve(), validate_config))
    prepare_view(valid, context, history)
  })
}

/// The text fallback keeps its summary in rolling's tables.
fn initialise(ledger: store.Store) -> Result(Nil, String) {
  use _ <- result.try(rolling.initialise(ledger))
  store.query(ledger, fn(db) {
    use _ <- result.try(store.exec(db, frame_schema <> archive_schema))
    // A failed prune only costs disk space, never a turn.
    let _ =
      store.exec(
        db,
        "DELETE FROM snapcompact_frames WHERE created_at < "
          <> int.to_string(now_ms() - frame_retention_ms),
      )
    Ok(Nil)
  })
}

fn prepare_view(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  case compaction.reads_images(context) {
    Some(False) -> text_view(context, history)
    _ -> visual_view(config, context, history)
  }
}

/// A model without image input cannot read frames: rolling's text summary
/// stands in, and the frame archive waits for a model that reads images.
fn text_view(
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  use prepared <- result.try(rolling.prepare_with_settings(context, history))
  Ok(
    compaction.Prepared(
      ..prepared,
      observation: option.map(prepared.observation, fn(observed) {
        compaction.Observation(
          ..observed,
          strategy: "snapcompact",
          source: "model reads no image input; rolling text compaction: "
            <> observed.source,
        )
      }),
    ),
  )
}

fn visual_view(
  config: Config,
  context: compaction.Context,
  history: List(types.Input),
) -> Result(compaction.Prepared, String) {
  // Other strategies' folds are already summaries: they stay as text ahead
  // of the archive, so the frame budget only ever drops raw rows.
  use compaction.Prior(folds, folded) <- result.try(context.prior(history))
  use saved <- result.try(load_archive(context.store, context.session))
  let resumed =
    option.then(saved, fn(archive) {
      compaction.resume(folded, archive.cut)
      |> result.map(fn(split) { #(archive, split.0, split.1) })
      |> option.from_result
    })
  use _ <- result.try(case saved, resumed {
    Some(_), None -> delete_archive(context.store, context.session)
    _, _ -> Ok(Nil)
  })
  let shape = fit(shape(context.model), context.images)
  let capacity = case context.capacity {
    Some(compaction.Capacity(tokens, _)) -> Some(tokens)
    None -> config.context_window_tokens
  }
  let limit =
    frame_budget(config, shape, context.reader, context.images, capacity)
  let #(previous, evicted, rest, current, status) = case resumed {
    None -> #(None, [], folded, folded, "not_needed")
    Some(#(archive, evicted, tail)) -> {
      let #(viewed, status) = view(context.store, shape, limit, archive, tail)
      #(Some(archive), evicted, tail, viewed, status)
    }
  }
  let estimated =
    context.pinned_tokens
    + compaction.estimate_inputs(folds)
    + compaction.estimate_inputs(current)
  let triggered =
    compaction.triggered(
      context.force,
      estimated,
      capacity,
      config.trigger_percent,
    )
  // Without a window the tail budget is a share of what the request holds.
  let tail_budget = case capacity {
    Some(tokens) ->
      compaction.tail_budget(
        tokens,
        estimated,
        context.force,
        config.tail_percent,
      )
    None -> int.max(estimated / 4, 1000)
  }
  let observe = fn(status, prepared) {
    observation(status, config, capacity, folds, folded, prepared)
  }
  use #(prepared, status, compacted) <- result.try(
    case triggered, compaction.split_tail(rest, tail_budget) {
      // Only a whole unit remains, or nothing is due: keep the saved cut.
      True, #([_, ..] as newly_evicted, tail) -> {
        let archive = extend(shape, limit, previous, evicted, newly_evicted)
        use _ <- result.try(save_archive(
          context.store,
          context.session,
          archive,
        ))
        let #(prepared, status) =
          view(context.store, shape, limit, archive, tail)
        Ok(#(prepared, status, True))
      }
      _, _ -> Ok(#(current, status, False))
    },
  )
  Ok(compaction.Prepared(
    list.append(folds, prepared),
    observe(status, prepared),
    compacted,
  ))
}

/// The archive after `newly_evicted` ages into it: the previous kept text,
/// then the new history, bounded again to the frame budget.
fn extend(
  shape: Shape,
  limit: Int,
  previous: Option(Archive),
  evicted: List(types.Input),
  newly_evicted: List(types.Input),
) -> Archive {
  let fresh = normalize(newly_evicted)
  let #(text, dropped) = case previous {
    Some(archive) -> #(archive.text <> newline_cell <> fresh, archive.dropped)
    None -> #(fresh, 0)
  }
  let #(text, trimmed) = bound(shape, limit, text)
  Archive(
    compaction.cut_of(list.append(evicted, newly_evicted)),
    text,
    dropped + trimmed,
  )
}

/// The archive as request inputs ahead of `tail`, and the view's status.
/// Rendering failure degrades to a verbatim tail, never a lost turn.
fn view(
  ledger: store.Store,
  shape: Shape,
  limit: Int,
  archive: Archive,
  tail: List(types.Input),
) -> #(List(types.Input), String) {
  // A stack with a smaller budget than the archive was saved under reads
  // only what fits; the saved text keeps the rest for a larger one.
  let #(text, trimmed) = bound(shape, limit, archive.text)
  case frames(ledger, shape, paginate(shape, text)) {
    Ok(images) -> #(
      list.append(archive_inputs(images, archive.dropped + trimmed), tail),
      "compacted",
    )
    Error(reason) -> {
      io.println_error(
        "snapcompact: archive withheld, frames failed: " <> reason,
      )
      #([types.User(truncation_note), ..tail], "fallback")
    }
  }
}

/// Frames per request: the provider's image budget, the inline byte budget,
/// and at most `archivePercent` of the window at the estimated cost of a
/// full frame. `maxFrames` replaces the provider caps.
fn frame_budget(
  config: Config,
  shape: Shape,
  reader: Option(compaction.Reader),
  images: types.ImageLimits,
  capacity: Option(Int),
) -> Int {
  let cap =
    option.lazy_unwrap(config.max_frames, fn() { provider_cap(reader, images) })
  let cost = compaction.image_tokens(shape.width, shape.rows * shape.pitch)
  case capacity {
    Some(tokens) ->
      int.clamp(tokens * config.archive_percent / 100 / cost, min: 1, max: cap)
    None -> cap
  }
}

/// The frames a provider's requests may carry. A provider that states how
/// many images a request takes keeps a tenth of them for the conversation's
/// own; otherwise oh-my-pi's per-request image budgets apply: policy caps
/// under the vendor limits (Anthropic 100, OpenAI 500, Gemini ~2500), with
/// `antigravity` taking Anthropic's, since it also serves Claude models.
fn provider_cap(
  reader: Option(compaction.Reader),
  limits: types.ImageLimits,
) -> Int {
  let provider = option.map(reader, fn(reader) { reader.provider })
  let images = case limits.max_images, provider {
    Some(images), _ -> images - images / 10
    None, provider -> known_cap(provider)
  }
  let bytes = case provider {
    Some("claude") -> max_frames
    _ -> frame_data_budget / frame_data_estimate
  }
  images |> int.min(bytes) |> int.min(max_frames)
}

fn known_cap(provider: Option(String)) -> Int {
  case provider {
    Some("anthropic")
    | Some("amazon-bedrock")
    | Some("openrouter")
    | Some("antigravity") -> 90
    Some("openai")
    | Some("openai-codex")
    | Some("google")
    | Some("google-vertex")
    | Some("google-gemini-cli") -> 200
    Some("umans") -> 10
    // oh-my-pi's floor for unmeasured providers; the strictest seen is ~5.
    _ -> 5
  }
}

fn observation(
  status: String,
  config: Config,
  capacity: Option(Int),
  folds: List(types.Input),
  before: List(types.Input),
  after: List(types.Input),
) -> Option(compaction.Observation) {
  let source = case status, folds {
    "not_needed", [] -> "durable transcript"
    "not_needed", _ -> "durable transcript through stored folds"
    _, [] ->
      "durable transcript through rendered bitmap frames and a verbatim tail"
    _, _ ->
      "durable transcript through stored folds, rendered bitmap frames, and a verbatim tail"
  }
  Some(compaction.observation(
    "snapcompact",
    status,
    source,
    source,
    config.trigger_percent,
    capacity,
    compaction.estimate_inputs(folds) + compaction.estimate_inputs(after),
    list.length(before),
    list.length(after),
  ))
}

/// `shape` held inside the provider's edge: a narrower frame, or fewer rows,
/// so a frame is rendered to fit rather than scaled afterwards.
pub fn fit(shape: Shape, limits: types.ImageLimits) -> Shape {
  Shape(
    ..shape,
    width: int.min(shape.width, limits.max_edge),
    rows: int.max(1, int.min(shape.rows, limits.max_edge / shape.pitch)),
  )
}

/// Geometry per vision stack: billing mode and measured glyph legibility.
pub fn shape(model: String) -> Shape {
  let name = string.lowercase(model)
  case string.contains(name, "gemini") || string.contains(name, "google") {
    True -> Shape(8, 22, 2048, 64)
    False ->
      case
        string.contains(name, "gpt")
        || string.contains(name, "codex")
        || string.contains(name, "o3")
        || string.contains(name, "o4")
      {
        True -> Shape(8, 22, 1568, 56)
        False -> Shape(11, 16, 1568, 44)
      }
  }
}

fn serialize(inputs: List(types.Input)) -> String {
  inputs
  |> compaction.without_superseded
  |> list.map(serialize_input)
  |> list.filter(fn(line) { line != "" })
  |> string.join("\n")
}

fn serialize_input(input: types.Input) -> String {
  case input {
    types.User(text) -> "¶user: " <> cap(text, message_chars)
    types.Assistant(text) -> "¶ai: " <> cap(text, message_chars)
    types.UserImage(text, image) ->
      "¶user: " <> cap(text, message_chars) <> " " <> image_note(image)
    types.ToolOutput(id, output, images) ->
      "¶out "
      <> cap(id, 80)
      <> ": "
      <> cap(output, result_chars)
      <> image_notes(images)
    types.Replay(item) -> serialize_replay(item)
  }
}

/// A replayed assistant turn: its text, then each tool call as
/// `→ name(key = value, ...)` with the arguments decoded, so code reads as
/// code instead of escaped JSON. A Responses item that is neither text nor a
/// call, such as encrypted reasoning, renders as nothing. A shape that does
/// not decode falls back to the raw JSON so no tool call is lost.
fn serialize_replay(item: types.ReplayItem) -> String {
  let protocol = types.replay_protocol(item)
  let decoded = case protocol {
    types.ChatCompletions -> types.inspect_item(item, replay_parts_decoder())
    types.Responses -> types.inspect_item(item, responses_parts_decoder())
  }
  case decoded {
    Ok(#("", [])) if protocol == types.Responses -> ""
    Ok(#(text, calls)) -> {
      let head = case text {
        "" -> "¶ai:"
        _ -> "¶ai: " <> cap(text, message_chars)
      }
      let calls =
        list.map(calls, fn(call) {
          "  → "
          <> call.name
          <> "("
          <> cap(format_args(cap(call.arguments, args_bytes)), call_args_chars)
          <> ")"
        })
      string.join([head, ..calls], "\n")
    }
    Error(_) -> replay_fallback(item)
  }
}

fn replay_fallback(item: types.ReplayItem) -> String {
  "¶turn: " <> cap(json.to_string(types.replay_json(item)), message_chars)
}

fn replay_parts_decoder() -> decode.Decoder(#(String, List(types.ToolCall))) {
  use text <- decode.optional_field(
    "content",
    "",
    decode.optional(decode.string) |> decode.map(option.unwrap(_, "")),
  )
  use calls <- decode.optional_field(
    "tool_calls",
    [],
    decode.list(call_decoder()),
  )
  decode.success(#(text, calls))
}

/// A Responses output item as text and calls: a message's text parts, or one
/// function call. Any other item decodes to nothing.
fn responses_parts_decoder() -> decode.Decoder(#(String, List(types.ToolCall))) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "message" -> {
      use parts <- decode.optional_field(
        "content",
        [],
        decode.list(decode.optional_field(
          "text",
          "",
          decode.string,
          decode.success,
        )),
      )
      decode.success(#(string.concat(parts), []))
    }
    "function_call" -> {
      use id <- decode.field("call_id", decode.string)
      use name <- decode.field("name", decode.string)
      use args <- decode.field("arguments", decode.string)
      decode.success(#("", [types.ToolCall(id, name, args)]))
    }
    _ -> decode.success(#("", []))
  }
}

fn call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.subfield(["function", "name"], decode.string)
  use args <- decode.subfield(["function", "arguments"], decode.string)
  decode.success(types.ToolCall(id, name, args))
}

fn image_notes(images: List(types.Image)) -> String {
  case images {
    [] -> ""
    _ -> " " <> string.join(list.map(images, image_note), " ")
  }
}

fn image_note(image: types.Image) -> String {
  let #(_, width, height, _) = types.image_meta(image)
  let hash = image_hash(image)
  "[image "
  <> string.slice(hash, 0, 8)
  <> " "
  <> int.to_string(width)
  <> "x"
  <> int.to_string(height)
  <> "]"
}

fn image_hash(image: types.Image) -> String {
  case types.image_data(image) {
    types.StoredData(stored, _, _) -> stored
    types.InlineData(data) -> sha256(data)
  }
}

fn cap(text: String, limit: Int) -> String {
  case string.length(text) > limit {
    True -> string.slice(text, 0, limit) <> " [+truncated]"
    False -> text
  }
}

/// Terminal escapes out, tabs expanded, and newline runs folded into
/// full-block cells: the archive is one continuous character stream that
/// wraps positionally, exactly as the reference renderer expects.
pub fn normalize(inputs: List(types.Input)) -> String {
  serialize(inputs) |> normalize_ansi
}

/// Chunks the continuous cell stream so one frame holds at most
/// `shape.rows` wrapped rows.
pub fn paginate(shape: Shape, text: String) -> List(String) {
  paginate_ffi(text, shape.width / shape.advance * shape.rows)
}

/// Keeps archive text within `limit` frames: the first frame, where the
/// session's task was set, and the newest after it. Whole frames between them
/// drop, so the kept frames stay aligned (and cached) across compactions.
/// Answers the kept text and how many characters were dropped.
pub fn bound(shape: Shape, limit: Int, text: String) -> #(String, Int) {
  let pages = paginate(shape, text)
  let count = list.length(pages)
  case count > limit {
    False -> #(text, 0)
    True -> {
      let head = case limit > 1 {
        True -> list.take(pages, 1)
        False -> []
      }
      let newest = list.drop(pages, count - limit + list.length(head))
      let dropped =
        pages
        |> list.drop(list.length(head))
        |> list.take(count - limit)
        |> list.fold(0, fn(total, page) { total + string.length(page) })
      #(string.concat(list.append(head, newest)), dropped)
    }
  }
}

/// Renders or reuses frames for each chunk, keyed by geometry and content so
/// an unchanged chunk never re-renders. Missing chunks render in one
/// subprocess; known rows serve metadata only and the payload reads lazily
/// at request time.
fn frames(
  ledger: store.Store,
  shape: Shape,
  chunks: List(String),
) -> Result(List(types.Image), String) {
  let keyed = list.map(chunks, fn(chunk) { #(chunk_key(shape, chunk), chunk) })
  let known =
    store.query(ledger, fn(db) {
      known_rows(db, list.map(keyed, fn(kv) { kv.0 }))
    })
  let missing = list.filter(keyed, fn(kv) { !dict.has_key(known, kv.0) })
  use rendered <- result.try(case missing {
    [] -> Ok([])
    _ ->
      render_frames(
        list.map(missing, fn(kv) { kv.1 }),
        shape.advance,
        shape.pitch,
        shape.width,
      )
  })
  let fresh =
    list.map2(missing, rendered, fn(kv, frame) {
      let #(width, height, bytes, data) = frame
      #(FrameRow(kv.0, sha256(data), width, height, bytes), data)
    })
  // A failed cache write only costs a re-render next request.
  let _ =
    store.query(ledger, fn(db) {
      list.each(fresh, fn(cached) {
        let #(row, data) = cached
        let _ =
          store.run(
            db,
            "INSERT OR IGNORE INTO snapcompact_frames(key,hash,data,width,height,bytes,created_at) VALUES(?,?,?,?,?,?,?)",
            [
              sqlight.text(row.key),
              sqlight.text(row.hash),
              sqlight.text(data),
              sqlight.int(row.width),
              sqlight.int(row.height),
              sqlight.int(row.bytes),
              sqlight.int(now_ms()),
            ],
          )
        Nil
      })
      Nil
    })
  let rows =
    dict.merge(known, rows_by_key(list.map(fresh, fn(cached) { cached.0 })))
  use kv <- list.try_map(keyed)
  use row <- result.try(
    dict.get(rows, kv.0)
    |> result.replace_error("frame row missing after render"),
  )
  frame_image(ledger, row)
}

fn rows_by_key(rows: List(FrameRow)) -> Dict(String, FrameRow) {
  list.map(rows, fn(row) { #(row.key, row) })
  |> dict.from_list
}

fn chunk_key(shape: Shape, chunk: String) -> String {
  sha256(
    int.to_string(shape.advance)
    <> "/"
    <> int.to_string(shape.pitch)
    <> "/"
    <> int.to_string(shape.width)
    <> "/"
    <> chunk,
  )
}

fn known_rows(
  db: sqlight.Connection,
  keys: List(String),
) -> Dict(String, FrameRow) {
  keys
  |> list.filter_map(fn(key) {
    store.one(
      db,
      "SELECT key,hash,width,height,bytes FROM snapcompact_frames WHERE key=?",
      [sqlight.text(key)],
      frame_row_decoder(),
      "frame row missing",
    )
  })
  |> rows_by_key
}

fn frame_row_decoder() -> decode.Decoder(FrameRow) {
  use key <- decode.field(0, decode.string)
  use hash <- decode.field(1, decode.string)
  use width <- decode.field(2, decode.int)
  use height <- decode.field(3, decode.int)
  use bytes <- decode.field(4, decode.int)
  decode.success(FrameRow(key, hash, width, height, bytes))
}

fn frame_image(
  ledger: store.Store,
  row: FrameRow,
) -> Result(types.Image, String) {
  types.stored_image(
    "image/png",
    row.hash,
    // Padded base64 length derived from the decoded byte count.
    { row.bytes + 2 } / 3 * 4,
    fn() { store.query(ledger, fn(db) { read_data(db, row.key) }) },
    row.width,
    row.height,
    row.bytes,
  )
  |> result.map_error(fn(error) { string.inspect(error) })
}

fn read_data(db: sqlight.Connection, key: String) -> Result(String, Nil) {
  store.one(
    db,
    "SELECT data FROM snapcompact_frames WHERE key=?",
    [sqlight.text(key)],
    decode.field(0, decode.string, decode.success),
    "frame data missing",
  )
  |> result.replace_error(Nil)
}

fn archive_inputs(
  images: List(types.Image),
  dropped: Int,
) -> List(types.Input) {
  case images {
    [] -> []
    [first, ..rest] -> [
      types.UserImage(archive_prompt(dropped), first),
      ..list.map(rest, fn(image) { types.UserImage("", image) })
    ]
  }
}

/// Rides the request prefix, so it changes only when a compaction drops more
/// history; any per-request number would invalidate the prompt cache.
fn archive_prompt(dropped: Int) -> String {
  let omitted = case dropped {
    0 -> ""
    _ ->
      " About "
      <> int.to_string(dropped)
      <> " characters of older history between the first image and the second were dropped to fit the archive budget; transcript_grep and transcript_read reach the original rows."
  }
  "The images below archive this session's earlier conversation verbatim, as dense fixed-width text a vision model reads directly. Read them like a transcript: each event starts after a solid black block cell, marked ¶user:, ¶ai:, ¶out, or ¶turn:; `[image h w]` notes where a picture was shown. Text wraps at the frame edge."
  <> omitted
  <> " The conversation continues as plain text after the last image."
}

fn load_archive(
  ledger: store.Store,
  session: String,
) -> Result(Option(Archive), String) {
  store.read(
    ledger,
    "SELECT users,fingerprint,text,dropped FROM snapcompact_archive WHERE session=?",
    [sqlight.text(session)],
    {
      use users <- decode.field(0, decode.int)
      use fingerprint <- decode.field(1, decode.string)
      use text <- decode.field(2, decode.string)
      use dropped <- decode.field(3, decode.int)
      decode.success(Archive(compaction.Cut(users, fingerprint), text, dropped))
    },
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

fn save_archive(
  ledger: store.Store,
  session: String,
  archive: Archive,
) -> Result(Nil, String) {
  store.write(
    ledger,
    "INSERT INTO snapcompact_archive(session,users,fingerprint,text,dropped) VALUES(?,?,?,?,?) ON CONFLICT(session) DO UPDATE SET users=excluded.users,fingerprint=excluded.fingerprint,text=excluded.text,dropped=excluded.dropped",
    [
      sqlight.text(session),
      sqlight.int(archive.cut.users),
      sqlight.text(archive.cut.fingerprint),
      sqlight.text(archive.text),
      sqlight.int(archive.dropped),
    ],
  )
}

fn delete_archive(ledger: store.Store, session: String) -> Result(Nil, String) {
  store.write(ledger, "DELETE FROM snapcompact_archive WHERE session=?", [
    sqlight.text(session),
  ])
}
