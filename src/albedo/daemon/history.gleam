//// Durable transcript paging and prefix forks. These operations never start a session actor.

import albedo/daemon/conversation
import albedo/daemon/events
import albedo/daemon/notice
import albedo/daemon/store
import albedo/harness/extensions/lcm/graph as lcm_graph
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

const default_page_size = 50

const max_page_size = 100

const incomplete_tool_result = "not executed after branch checkpoint"

pub type Kind {
  User
  Assistant
  Tool
}

pub type Item {
  Item(id: Int, kind: Kind, preview: String, timestamp: Option(Int))
}

pub type Page {
  Page(items: List(Item), next_cursor: Option(Int), has_more: Bool)
}

type Row {
  Row(seq: Int, input: types.Input, timestamp: Option(Int))
}

/// Read one bounded page directly from the durable transcript. `after` is an
/// exclusive transcript sequence cursor; no session actor or in-memory history
/// is involved.
pub fn page(
  ledger: store.Store,
  session_id: String,
  after: Int,
  requested_limit: Int,
) -> Result(Page, String) {
  let limit = clamp_limit(requested_limit, default_page_size)
  store.query(ledger, fn(db) {
    use rows <- result.try(store.rows(
      db,
      "SELECT seq,payload,timestamp,provider FROM transcript WHERE session=? AND seq>? ORDER BY seq LIMIT ?",
      [
        sqlight.text(session_id),
        sqlight.int(int.max(after, 0)),
        sqlight.int(limit + 1),
      ],
      row_decoder(),
    ))
    use decoded <- result.try(list.try_map(rows, decode_row))
    let has_more = list.length(decoded) > limit
    let visible = list.take(decoded, limit)
    let items = list.map(visible, row_item)
    let next_cursor =
      option.map(option.from_result(list.last(items)), fn(item) { item.id })
    Ok(Page(items, next_cursor, has_more))
  })
}

/// Up to `rows` transcript rows before `before` (None: the newest), rendered
/// as the stream renders them, with `committed` markers, as a JSON body:
/// {"events":[...],"before":first row,"more":older rows remain}.
pub fn rendered(
  ledger: store.Store,
  session_id: String,
  before: Option(Int),
  rows: Int,
) -> Result(String, String) {
  use #(entries, more) <- result.try(conversation.load_tail(
    ledger,
    session_id,
    before,
    rows,
  ))
  let page = json.object(events.page_fields(entries, more)) |> json.to_string
  Ok(
    "{\"events\":["
    <> string.join(events.rows(ledger, entries), ",")
    <> "],"
    <> string.drop_start(page, 1),
  )
}

pub type Recent {
  Recent(items: List(Item), total: Int)
}

const recent_excerpt = 400

const recent_tool_excerpt = 120

/// The newest conversational items of a transcript, oldest first, for the
/// session list's preview pane. Excerpts are longer than tree previews, bodiless
/// provider items are skipped, and `total` counts every transcript row. Like
/// `page`, this reads only the durable ledger.
pub fn recent(
  ledger: store.Store,
  session_id: String,
  requested_limit: Int,
) -> Result(Recent, String) {
  let limit = clamp_limit(requested_limit, 12)
  store.query(ledger, fn(db) {
    use total <- result.try(store.rows(
      db,
      "SELECT COUNT(*) FROM transcript WHERE session=?",
      [sqlight.text(session_id)],
      decode.field(0, decode.int, decode.success),
    ))
    // Reasoning-only rows are dropped below, so read past the limit to keep
    // the pane full.
    use rows <- result.try(store.rows(
      db,
      "SELECT seq,payload,timestamp,provider FROM transcript WHERE session=? ORDER BY seq DESC LIMIT ?",
      [sqlight.text(session_id), sqlight.int(limit * 4)],
      row_decoder(),
    ))
    use decoded <- result.try(list.try_map(rows, decode_row))
    let items =
      decoded
      |> list.filter_map(recent_item)
      |> list.take(limit)
      |> list.reverse
    Ok(Recent(items, list.first(total) |> result.unwrap(0)))
  })
}

fn recent_item(row: Row) -> Result(Item, Nil) {
  let item = fn(kind, text, limit) {
    case conversation.excerpt(text, limit) {
      "" -> Error(Nil)
      clean -> Ok(Item(row.seq, kind, clean, row.timestamp))
    }
  }
  case row.input {
    types.User(text) ->
      case notice.is_notice(text) {
        True -> Error(Nil)
        False -> item(User, text, recent_excerpt)
      }
    types.UserImage(text, image) ->
      case notice.is_notice(text) {
        True -> Error(Nil)
        False -> item(User, text <> image_label(image), recent_excerpt)
      }
    types.Assistant(text) -> item(Assistant, text, recent_excerpt)
    types.ToolOutput(_, _, _) -> Error(Nil)
    types.Replay(replay) ->
      case preview_of(replay) {
        Answer(text) -> item(Assistant, text, recent_excerpt)
        Calls(names) ->
          item(Tool, string.join(names, ", "), recent_tool_excerpt)
        Bare -> Error(Nil)
      }
  }
}

/// Create a durable, idle session containing exactly the selected prefix plus
/// protocol-completing results for tool calls interrupted by the checkpoint.
/// Runtime, Python, request-strategy, and usage state are intentionally absent.
pub fn fork(
  ledger: store.Store,
  source_id: String,
  branch_id: String,
  checkpoint: Int,
) -> Result(conversation.Info, String) {
  case
    source_id != branch_id
    && checkpoint > 0
    && string.byte_size(branch_id) > 0
    && string.byte_size(branch_id) <= 200
  {
    False -> Error("invalid branch checkpoint or session id")
    True ->
      store.query(ledger, fn(db) {
        store.transaction(db, fn() {
          use source <- result.try(conversation.read_info(db, source_id))
          use rows <- result.try(read_prefix(db, source_id, checkpoint))
          use _ <- result.try(case list.last(rows) {
            Ok(row) if row.seq == checkpoint -> Ok(Nil)
            _ -> Error("checkpoint not found")
          })
          use pending <- result.try(unmatched_calls(rows))
          let title = prefix_title(rows)
          use _ <- result.try(insert_session(db, source, branch_id, title))
          use _ <- result.try(copy_prefix(db, source_id, branch_id, checkpoint))
          use _ <- result.try(lcm_graph.inherit_fork_prefix(
            db,
            source_id,
            branch_id,
            checkpoint,
            list.map(rows, fn(row) { row.seq }),
          ))
          use _ <- result.try(copy_extension_overrides(db, source_id, branch_id))
          use _ <- result.try(append_incomplete_results(
            db,
            branch_id,
            source.provider,
            pending,
          ))
          Ok(conversation.Info(
            branch_id,
            title,
            source.cwd,
            source.provider,
            source.model,
            source.protocol,
            conversation.Idle,
            None,
            source.effort,
          ))
        })
      })
  }
}

pub fn kind_name(kind: Kind) -> String {
  case kind {
    User -> "user"
    Assistant -> "assistant"
    Tool -> "tool"
  }
}

fn row_decoder() {
  use seq <- decode.field(0, decode.int)
  use payload <- decode.field(1, decode.bit_array)
  use timestamp <- decode.field(2, decode.optional(decode.int))
  decode.success(#(seq, payload, timestamp))
}

fn decode_row(row) -> Result(Row, String) {
  let #(seq, payload, timestamp) = row
  use input <- result.try(
    unpack(payload, unread)
    |> result.replace_error("invalid saved transcript item"),
  )
  Ok(Row(seq, input, timestamp))
}

/// A page's size: a non-positive request falls back to `default`.
fn clamp_limit(requested: Int, default: Int) -> Int {
  case requested <= 0 {
    True -> default
    False -> int.min(requested, max_page_size)
  }
}

fn row_item(row: Row) -> Item {
  let #(kind, text) = case row.input {
    types.User(text) -> #(User, text)
    types.UserImage(text, image) -> #(User, text <> image_label(image))
    types.Assistant(text) -> #(Assistant, text)
    types.ToolOutput(_, output, images) -> #(
      Tool,
      output <> string.concat(list.map(images, image_label)),
    )
    types.Replay(item) -> replay_preview(item)
  }
  Item(row.seq, kind, safe_preview(text), row.timestamp)
}

fn image_label(image: types.Image) -> String {
  let #(mime, width, height, _) = types.image_meta(image)
  " ["
  <> mime
  <> " "
  <> int.to_string(width)
  <> "x"
  <> int.to_string(height)
  <> "]"
}

/// What a provider item previews as: the names of its calls, its answer
/// text, or neither.
type Preview {
  Calls(names: List(String))
  Answer(String)
  Bare
}

fn preview_of(item: types.ReplayItem) -> Preview {
  let names = list.map(events.calls(types.Replay(item)), fn(call) { call.name })
  case names, events.visible_assistant_text(types.Replay(item)) {
    [_, ..], _ -> Calls(names)
    [], Some(text) -> Answer(text)
    [], None -> Bare
  }
}

fn replay_preview(item: types.ReplayItem) -> #(Kind, String) {
  case preview_of(item) {
    Calls(names) -> #(Tool, "call " <> string.join(names, ", "))
    Answer(text) -> #(Assistant, text)
    Bare ->
      case events.thinking_text(item) {
        "" -> #(Assistant, "[provider item]")
        text -> #(Assistant, "[reasoning] " <> text)
      }
  }
}

fn safe_preview(text: String) -> String {
  case conversation.title(text) {
    "new session" -> "[empty]"
    preview -> preview
  }
}

fn read_prefix(db, id: String, checkpoint: Int) -> Result(List(Row), String) {
  use rows <- result.try(store.rows(
    db,
    "SELECT seq,payload,timestamp,provider FROM transcript WHERE session=? AND seq<=? ORDER BY seq",
    [sqlight.text(id), sqlight.int(checkpoint)],
    row_decoder(),
  ))
  list.try_map(rows, decode_row)
}

fn prefix_title(rows: List(Row)) -> String {
  rows
  |> list.map(fn(row) { row.input })
  |> conversation.latest_user
  |> conversation.title_or_default
}

fn unmatched_calls(rows: List(Row)) -> Result(List(String), String) {
  list.try_fold(rows, [], fn(pending, row) {
    case row.input {
      types.Replay(_) ->
        list.try_fold(events.calls(row.input), pending, fn(pending, call) {
          case list.contains(pending, call.id) {
            True -> Error("duplicate tool call id before checkpoint")
            False -> Ok(list.append(pending, [call.id]))
          }
        })
      types.ToolOutput(id, _, _) ->
        case list.contains(pending, id) {
          True -> Ok(list.filter(pending, fn(value) { value != id }))
          False -> Error("checkpoint contains a tool result without its call")
        }
      _ -> Ok(pending)
    }
  })
}

fn insert_session(
  db,
  source: conversation.Info,
  id: String,
  title: String,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO sessions(id,title,cwd,provider,model,protocol,stage,activity_seq,last_assistant_at) SELECT ?,?,?,?,?,?,'idle',COALESCE(MAX(activity_seq),0)+1,NULL FROM sessions",
    [
      sqlight.text(id),
      sqlight.text(title),
      sqlight.text(source.cwd),
      sqlight.text(source.provider),
      sqlight.text(source.model),
      sqlight.text(conversation.protocol(source.protocol)),
    ],
  )
}

fn copy_prefix(
  db,
  source_id: String,
  branch_id: String,
  checkpoint: Int,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO transcript(session,payload,timestamp,provider,thought_ms) SELECT ?,payload,timestamp,provider,thought_ms FROM transcript WHERE session=? AND seq<=? ORDER BY seq",
    [sqlight.text(branch_id), sqlight.text(source_id), sqlight.int(checkpoint)],
  )
}

fn copy_extension_overrides(
  db,
  source_id: String,
  branch_id: String,
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO session_extensions(session,name,enabled) SELECT ?,name,enabled FROM session_extensions WHERE session=?",
    [sqlight.text(branch_id), sqlight.text(source_id)],
  )
}

fn append_incomplete_results(
  db,
  branch_id: String,
  provider: String,
  pending: List(String),
) -> Result(Nil, String) {
  list.try_each(pending, fn(call_id) {
    store.run(
      db,
      "INSERT INTO transcript(session,payload,timestamp,provider) VALUES(?,?,NULL,?)",
      [
        sqlight.text(branch_id),
        sqlight.blob(
          pack(types.ToolOutput(call_id, incomplete_tool_result, [])),
        ),
        sqlight.text(provider),
      ],
    )
  })
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_conversation", "unpack")
fn unpack(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, Nil)

/// History rows are previews and fork bookkeeping (a fork copies payload bytes,
/// references included); none is sent to a model, so none reads an image.
fn unread(_hash: String) -> Result(String, Nil) {
  Error(Nil)
}
