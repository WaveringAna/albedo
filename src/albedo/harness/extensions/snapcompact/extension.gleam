//// Compaction that archives discarded history as rendered bitmap frames the
//// vision stack reads directly, instead of a lossy summary. Frames are X11
//// 8x13 pixel-font text through the local albedo-render binary, cached in
//// `snapcompact_frames` keyed by geometry and content, so re-preparing a
//// request re-renders nothing. Frames assume the model accepts image input;
//// disable via settings for text-only models.

import albedo/daemon/store
import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/settings
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const default_trigger_percent = 90

const default_tail_percent = 25

/// Frame cap per compaction; older frames are dropped, newest kept.
const max_frames = 8

const result_chars = 1600

const message_chars = 8000

const call_args_chars = 1500

/// Bound on the arguments JSON before it is decoded for formatting.
const args_bytes = 8192

/// Cached frames unreferenced this long are pruned at startup.
const frame_retention_ms = 2_592_000_000

const frame_schema = "CREATE TABLE IF NOT EXISTS snapcompact_frames(key TEXT PRIMARY KEY,hash TEXT NOT NULL,data TEXT NOT NULL,width INTEGER NOT NULL,height INTEGER NOT NULL,bytes INTEGER NOT NULL,created_at INTEGER NOT NULL);"

const truncation_note = "The conversation above this message was truncated; its earlier history could not be archived."

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
fn paginate_ffi(text: String, per_frame: Int, max: Int) -> List(String)

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
    enabled: Bool,
  )
}

pub type Shape {
  Shape(advance: Int, pitch: Int, width: Int, rows: Int)
}

type FrameRow {
  FrameRow(key: String, hash: String, width: Int, height: Int, bytes: Int)
}

pub fn default_config() -> Config {
  Config(None, default_trigger_percent, default_tail_percent, True)
}

pub fn config_decoder() {
  use capacity <- decode.optional_field(
    "contextWindowTokens",
    None,
    decode.optional(decode.int),
  )
  use trigger <- decode.optional_field("triggerPercent", 90, decode.int)
  use tail <- decode.optional_field("tailPercent", 25, decode.int)
  use enabled <- decode.optional_field("enabled", True, decode.bool)
  decode.success(Config(capacity, trigger, tail, enabled))
}

pub fn load_config() -> Result(Config, String) {
  use config <- result.try(settings.load(
    "snapcompact",
    config_decoder(),
    default_config(),
  ))
  validate_config(config)
}

pub fn load_config_at(home: String) -> Result(Config, String) {
  use config <- result.try(settings.load_at(
    home,
    "snapcompact",
    config_decoder(),
    default_config(),
  ))
  validate_config(config)
}

fn validate_config(config: Config) -> Result(Config, String) {
  case config.context_window_tokens {
    Some(capacity) if capacity <= 0 ->
      Error("snapcompact contextWindowTokens must be positive")
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
            "snapcompact percentages must satisfy 0 < tailPercent < triggerPercent < 100",
          )
      }
  }
}

/// Registration only gates plugin presence on configuration; the strategy
/// reloads settings per compaction so edits apply without a daemon restart.
pub fn extension() -> extension.Extension {
  extension.Extension(
    "snapcompact",
    "History archived as rendered bitmap frames the vision stack reads directly",
    [],
    compaction_plugins(),
    initialise,
  )
}

fn compaction_plugins() -> List(extension.Plugin) {
  case load_config() {
    Ok(_) -> [
      extension.CompactionPlugin(
        compaction.Strategy("snapcompact", fn(context, history) {
          use valid <- result.try(load_config())
          prepare_view(valid, context, history)
        }),
      ),
    ]
    Error(_) -> []
  }
}

pub fn initialise(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    case sqlight.exec(frame_schema, db) {
      Ok(_) -> {
        // A failed prune only costs disk space, never a turn.
        let _ =
          sqlight.exec(
            "DELETE FROM snapcompact_frames WHERE created_at < "
              <> int.to_string(now_ms() - frame_retention_ms),
            db,
          )
        Ok(Nil)
      }
      Error(e) -> Error(e.message)
    }
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
  let estimated = context.pinned_tokens + compaction.estimate_inputs(folded)
  let capacity = case context.capacity {
    Some(compaction.Capacity(tokens, _)) -> Some(tokens)
    None -> config.context_window_tokens
  }
  let compacted = case context.force {
    True -> True
    False ->
      case capacity {
        Some(tokens) -> estimated >= tokens * config.trigger_percent / 100
        None -> False
      }
  }
  case compacted, has_user_boundary(folded) {
    False, _ ->
      Ok(compaction.Prepared(folded, observation("idle", folded, folded)))
    True, False ->
      // No user boundary to cut at: an archive would orphan tool pairs.
      Ok(compaction.Prepared(folded, observation("idle", folded, folded)))
    True, True -> {
      let tail_tokens = case capacity {
        Some(tokens) -> tokens * config.tail_percent / 100
        None -> int.max(estimated / 4, 1000)
      }
      let #(evicted, tail) = cut(tail_tokens, folded)
      let text = normalize(evicted)
      let shape = shape(context.model)
      let chunks = paginate(shape, text)
      case chunks {
        [] ->
          Ok(compaction.Prepared(folded, observation("idle", folded, folded)))
        _ ->
          case frames(context.store, shape, chunks) {
            Ok(images) -> {
              let prepared = list.append(archive_inputs(images), tail)
              Ok(compaction.Prepared(
                prepared,
                observation("compacted", folded, prepared),
              ))
            }
            // Rendering failure degrades to a verbatim tail, never a lost
            // turn: the strategy must not error here.
            Error(_) -> {
              let prepared = [types.User(truncation_note), ..tail]
              Ok(compaction.Prepared(
                prepared,
                observation("fallback", folded, prepared),
              ))
            }
          }
      }
    }
  }
}

fn observation(
  status: String,
  before: List(types.Input),
  after: List(types.Input),
) -> Option(compaction.Observation) {
  Some(compaction.Observation(
    "snapcompact",
    status,
    "durable transcript through rendered bitmap frames and a verbatim tail",
    "durable transcript through rendered bitmap frames and a verbatim tail",
    None,
    None,
    Some(compaction.estimate_inputs(after)),
    Some("local byte-based estimate; not provider token usage"),
    Some(list.length(before)),
    Some(list.length(after)),
  ))
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
  |> list.map(serialize_input)
  |> string.join("\n")
}

fn serialize_input(input: types.Input) -> String {
  case input {
    types.User(text) -> "¶user: " <> cap(text, message_chars)
    types.Assistant(text) -> "¶ai: " <> cap(text, message_chars)
    types.UserImage(text, image) ->
      "¶user: " <> cap(text, message_chars) <> " " <> image_note(image)
    types.ToolOutput(id, output, []) ->
      "¶out " <> cap(id, 80) <> ": " <> cap(output, result_chars)
    types.ToolOutput(id, output, images) ->
      "¶out "
      <> cap(id, 80)
      <> ": "
      <> cap(output, result_chars)
      <> " "
      <> string.join(list.map(images, image_note), " ")
    types.Replay(item) -> serialize_replay(item)
  }
}

/// A replayed assistant turn: its text, then each tool call as
/// `→ name(key = value, ...)` with the arguments decoded, so code reads as
/// code instead of escaped JSON. Only the chat-completions shape is decoded;
/// anything else falls back to the raw JSON so no tool call is lost.
fn serialize_replay(item: types.ReplayItem) -> String {
  case types.replay_protocol(item) {
    types.ChatCompletions ->
      case types.inspect_item(item, replay_parts_decoder()) {
        Ok(#(text, calls)) -> {
          let head = case text {
            "" -> "¶ai:"
            _ -> "¶ai: " <> cap(text, message_chars)
          }
          let calls =
            calls
            |> list.map(fn(call) {
              "  → "
              <> call.name
              <> "("
              <> cap(
                format_args(cap(call.arguments, args_bytes)),
                call_args_chars,
              )
              <> ")"
            })
          string.join([head, ..calls], "\n")
        }
        Error(_) -> replay_fallback(item)
      }
    types.Responses -> replay_fallback(item)
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

fn call_decoder() -> decode.Decoder(types.ToolCall) {
  use id <- decode.field("id", decode.string)
  use name <- decode.subfield(["function", "name"], decode.string)
  use args <- decode.subfield(["function", "arguments"], decode.string)
  decode.success(types.ToolCall(id, name, args))
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
/// `shape.rows` wrapped rows; whole leading frames are dropped so frame
/// boundaries stay aligned, keeping only the newest `max_frames`.
pub fn paginate(shape: Shape, text: String) -> List(String) {
  let columns = shape.width / shape.advance
  paginate_ffi(text, columns * shape.rows, max_frames)
}

/// Renders or reuses frames for each chunk, keyed by geometry and content so
/// an unchanged chunk never re-renders. Missing chunks render in one
/// subprocess; known rows serve metadata only and the payload reads lazily
/// at request time.
pub fn frames(
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
      FrameRow(kv.0, sha256(data), width, height, bytes)
    })
  // A failed cache write only costs a re-render next request.
  let _ =
    store.query(ledger, fn(db) {
      list.each(fresh, fn(row: FrameRow) {
        insert_row(
          db,
          row,
          dict.get(rendered_by_key(missing, rendered), row.key),
        )
      })
      Nil
    })
  let rows = dict.merge(known, rows_by_key(fresh))
  list.try_map(keyed, fn(kv) {
    case dict.get(rows, kv.0) {
      Ok(row) -> frame_image(ledger)(row)
      Error(Nil) -> Error("frame row missing after render")
    }
  })
}

fn rows_by_key(rows: List(FrameRow)) -> Dict(String, FrameRow) {
  list.fold(rows, dict.new(), fn(acc, row: FrameRow) {
    dict.insert(acc, row.key, row)
  })
}

fn rendered_by_key(
  missing: List(#(String, String)),
  rendered: List(#(Int, Int, Int, String)),
) -> Dict(String, String) {
  list.map2(missing, rendered, fn(kv, frame) { #(kv.0, frame.3) })
  |> list.fold(dict.new(), fn(acc, kv) { dict.insert(acc, kv.0, kv.1) })
}

fn insert_row(
  db: sqlight.Connection,
  row: FrameRow,
  data: Result(String, Nil),
) -> Nil {
  case data {
    Ok(data) -> {
      let _ =
        sqlight.query(
          "INSERT OR IGNORE INTO snapcompact_frames(key,hash,data,width,height,bytes,created_at) VALUES(?,?,?,?,?,?,?)",
          db,
          [
            sqlight.text(row.key),
            sqlight.text(row.hash),
            sqlight.text(data),
            sqlight.int(row.width),
            sqlight.int(row.height),
            sqlight.int(row.bytes),
            sqlight.int(now_ms()),
          ],
          decode.dynamic,
        )
      Nil
    }
    Error(Nil) -> Nil
  }
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
    sqlight.query(
      "SELECT key,hash,width,height,bytes FROM snapcompact_frames WHERE key=?",
      db,
      [sqlight.text(key)],
      frame_row_decoder(),
    )
    |> result.replace_error(Nil)
    |> result.try(fn(rows) { result.replace_error(list.first(rows), Nil) })
  })
  |> list.fold(dict.new(), fn(acc, row: FrameRow) {
    dict.insert(acc, row.key, row)
  })
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
) -> fn(FrameRow) -> Result(types.Image, String) {
  fn(row: FrameRow) -> Result(types.Image, String) {
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
}

fn read_data(db: sqlight.Connection, key: String) -> Result(String, Nil) {
  case
    sqlight.query(
      "SELECT data FROM snapcompact_frames WHERE key=?",
      db,
      [sqlight.text(key)],
      decode.field(0, decode.string, decode.success),
    )
  {
    Ok([data]) -> Ok(data)
    _ -> Error(Nil)
  }
}

/// Splits so the tail keeps at least `budget` estimated tokens, then moves
/// the boundary back to a user message so tool call/result pairs never
/// straddle it: a result without its call is a request error.
pub fn cut(
  budget: Int,
  history: List(types.Input),
) -> #(List(types.Input), List(types.Input)) {
  let #(tail, evicted_rev) = take_tail(list.reverse(history), [], 0, budget)
  let #(moved, kept) = snap_to_user(tail)
  #(list.append(list.reverse(evicted_rev), moved), kept)
}

fn take_tail(
  reversed: List(types.Input),
  acc: List(types.Input),
  spent: Int,
  budget: Int,
) -> #(List(types.Input), List(types.Input)) {
  case spent >= budget, reversed {
    True, [item, ..rest] -> #(acc, [item, ..rest])
    True, [] -> #(acc, [])
    False, [item, ..rest] ->
      take_tail(
        rest,
        [item, ..acc],
        spent + compaction.estimate_input(item),
        budget,
      )
    False, [] -> #(acc, [])
  }
}

fn snap_to_user(
  tail: List(types.Input),
) -> #(List(types.Input), List(types.Input)) {
  let #(moved, kept) =
    list.split_while(tail, fn(input) {
      case input {
        types.User(_) | types.UserImage(_, _) -> False
        _ -> True
      }
    })
  #(moved, kept)
}

fn has_user_boundary(history: List(types.Input)) -> Bool {
  history
  |> list.any(fn(input) {
    case input {
      types.User(_) | types.UserImage(_, _) -> True
      _ -> False
    }
  })
}

fn archive_inputs(images: List(types.Image)) -> List(types.Input) {
  case images {
    [] -> []
    [first, ..rest] -> [
      types.UserImage(archive_prompt(), first),
      ..list.map(rest, fn(image) { types.UserImage("", image) })
    ]
  }
}

/// Static on purpose: the prompt rides the request prefix, and any changing
/// number would invalidate the provider's prompt cache.
fn archive_prompt() -> String {
  "The images below archive this session's earlier conversation verbatim, as dense fixed-width text a vision model reads directly. Read them like a transcript: each event starts after a solid black block cell, marked ¶user:, ¶ai:, ¶out, or ¶turn:; `[image h w]` notes where a picture was shown. Text wraps at the frame edge, and the oldest events may be omitted. The conversation continues as plain text after the last image."
}
