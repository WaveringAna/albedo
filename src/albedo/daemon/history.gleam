//// Durable transcript paging and prefix forks. These operations never start a session actor.

import albedo/daemon/conversation
import albedo/daemon/events
import albedo/daemon/store
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
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
  Row(
    seq: Int,
    payload: BitArray,
    input: types.Input,
    timestamp: Option(Int),
    provider: Option(String),
  )
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
  let limit = case requested_limit <= 0 {
    True -> default_page_size
    False -> int.min(requested_limit, max_page_size)
  }
  store.query(ledger, fn(db) {
    use rows <- result.try(
      sqlight.query(
        "SELECT seq,payload,timestamp,provider FROM transcript WHERE session=? AND seq>? ORDER BY seq LIMIT ?",
        db,
        [
          sqlight.text(session_id),
          sqlight.int(int.max(after, 0)),
          sqlight.int(limit + 1),
        ],
        row_decoder(),
      )
      |> result.map_error(fn(error) { error.message }),
    )
    use decoded <- result.try(list.try_map(rows, decode_row))
    let has_more = list.length(decoded) > limit
    let visible = list.take(decoded, limit)
    let items = list.map(visible, row_item)
    let next_cursor = case list.last(items) {
      Ok(item) -> Some(item.id)
      Error(_) -> None
    }
    Ok(Page(items, next_cursor, has_more))
  })
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
        use _ <- result.try(
          sqlight.exec("BEGIN IMMEDIATE", db)
          |> result.map_error(fn(error) { error.message }),
        )
        let written = {
          use source <- result.try(read_info(db, source_id))
          use rows <- result.try(read_prefix(db, source_id, checkpoint))
          use _ <- result.try(case list.last(rows) {
            Ok(row) if row.seq == checkpoint -> Ok(Nil)
            _ -> Error("checkpoint not found")
          })
          use pending <- result.try(unmatched_calls(rows))
          let title = prefix_title(rows)
          use _ <- result.try(insert_session(db, source, branch_id, title))
          use _ <- result.try(copy_prefix(db, source_id, branch_id, checkpoint))
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
            "idle",
            None,
          ))
        }
        case written {
          Ok(info) ->
            sqlight.exec("COMMIT", db)
            |> result.replace(info)
            |> result.map_error(fn(error) { error.message })
          Error(error) -> {
            let _ = sqlight.exec("ROLLBACK", db)
            Error(error)
          }
        }
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
  use provider <- decode.field(3, decode.optional(decode.string))
  decode.success(#(seq, payload, timestamp, provider))
}

fn decode_row(row) -> Result(Row, String) {
  let #(seq, payload, timestamp, provider) = row
  use input <- result.try(
    unpack(payload) |> result.replace_error("invalid saved transcript item"),
  )
  Ok(Row(seq, payload, input, timestamp, provider))
}

fn row_item(row: Row) -> Item {
  let #(kind, text) = case row.input {
    types.User(text) -> #(User, text)
    types.UserImage(text, image) -> {
      let #(mime, _, width, height, _) = types.image_parts(image)
      #(
        User,
        text
          <> " ["
          <> mime
          <> " "
          <> int.to_string(width)
          <> "x"
          <> int.to_string(height)
          <> "]",
      )
    }
    types.Assistant(text) -> #(Assistant, text)
    types.ToolOutput(_, output) -> #(Tool, output)
    types.Replay(item) -> replay_preview(item)
  }
  Item(row.seq, kind, safe_preview(text), row.timestamp)
}

fn replay_preview(item: types.ReplayItem) -> #(Kind, String) {
  case events.calls(types.Replay(item)) {
    [call, ..rest] -> {
      let names =
        [call, ..rest]
        |> list.map(fn(call) { call.name })
        |> string.join(", ")
      #(Tool, "call " <> names)
    }
    [] ->
      case events.visible_assistant_text(types.Replay(item)) {
        Some(text) -> #(Assistant, text)
        None -> {
          let reasoning = events.thinking_text(item)
          case reasoning {
            "" -> #(Assistant, "[provider item]")
            text -> #(Assistant, "[reasoning] " <> text)
          }
        }
      }
  }
}

fn safe_preview(text: String) -> String {
  case conversation.title(text) {
    "new session" -> "[empty]"
    preview -> preview
  }
}

fn info_decoder() {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use cwd <- decode.field(2, decode.string)
  use provider <- decode.field(3, decode.string)
  use model <- decode.field(4, decode.string)
  use protocol <- decode.field(5, decode.string)
  use stage <- decode.field(6, decode.string)
  use last_assistant_at <- decode.field(7, decode.optional(decode.int))
  decode.success(conversation.Info(
    id,
    title,
    cwd,
    provider,
    model,
    case protocol {
      "responses" -> types.Responses
      _ -> types.ChatCompletions
    },
    stage,
    last_assistant_at,
  ))
}

fn read_info(db, id: String) -> Result(conversation.Info, String) {
  sqlight.query(
    "SELECT id,COALESCE(NULLIF(title,''),'new session'),cwd,COALESCE(provider,''),model,protocol,stage,last_assistant_at FROM sessions WHERE id=?",
    db,
    [sqlight.text(id)],
    info_decoder(),
  )
  |> result.map_error(fn(error) { error.message })
  |> result.try(fn(rows) {
    list.first(rows) |> result.replace_error("session not found")
  })
}

fn read_prefix(db, id: String, checkpoint: Int) -> Result(List(Row), String) {
  sqlight.query(
    "SELECT seq,payload,timestamp,provider FROM transcript WHERE session=? AND seq<=? ORDER BY seq",
    db,
    [sqlight.text(id), sqlight.int(checkpoint)],
    row_decoder(),
  )
  |> result.map_error(fn(error) { error.message })
  |> result.try(fn(rows) { list.try_map(rows, decode_row) })
}

fn prefix_title(rows: List(Row)) -> String {
  rows
  |> list.fold(None, fn(latest, row) {
    case row.input {
      types.User(text) | types.UserImage(text, _) -> Some(text)
      _ -> latest
    }
  })
  |> fn(latest) {
    case latest {
      Some(text) -> conversation.title(text)
      None -> "new session"
    }
  }
}

fn unmatched_calls(rows: List(Row)) -> Result(List(String), String) {
  list.fold(rows, Ok([]), fn(state, row) {
    use pending <- result.try(state)
    case row.input {
      types.Replay(_) ->
        events.calls(row.input)
        |> list.fold(Ok(pending), fn(state, call) {
          use pending <- result.try(state)
          case list.contains(pending, call.id) {
            True -> Error("duplicate tool call id before checkpoint")
            False -> Ok(list.append(pending, [call.id]))
          }
        })
      types.ToolOutput(id, _) ->
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
  sqlight.query(
    "INSERT INTO sessions(id,title,cwd,provider,model,protocol,stage,activity_seq,last_assistant_at) SELECT ?,?,?,?,?,?,'idle',COALESCE(MAX(activity_seq),0)+1,NULL FROM sessions",
    db,
    [
      sqlight.text(id),
      sqlight.text(title),
      sqlight.text(source.cwd),
      sqlight.text(source.provider),
      sqlight.text(source.model),
      sqlight.text(conversation.protocol(source.protocol)),
    ],
    decode.dynamic,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) { error.message })
}

fn copy_prefix(
  db,
  source_id: String,
  branch_id: String,
  checkpoint: Int,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO transcript(session,payload,timestamp,provider) SELECT ?,payload,timestamp,provider FROM transcript WHERE session=? AND seq<=? ORDER BY seq",
    db,
    [
      sqlight.text(branch_id),
      sqlight.text(source_id),
      sqlight.int(checkpoint),
    ],
    decode.dynamic,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) { error.message })
}

fn copy_extension_overrides(
  db,
  source_id: String,
  branch_id: String,
) -> Result(Nil, String) {
  sqlight.query(
    "INSERT INTO session_extensions(session,name,enabled) SELECT ?,name,enabled FROM session_extensions WHERE session=?",
    db,
    [sqlight.text(branch_id), sqlight.text(source_id)],
    decode.dynamic,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(error) { error.message })
}

fn append_incomplete_results(
  db,
  branch_id: String,
  provider: String,
  pending: List(String),
) -> Result(Nil, String) {
  list.try_each(pending, fn(call_id) {
    sqlight.query(
      "INSERT INTO transcript(session,payload,timestamp,provider) VALUES(?,?,NULL,?)",
      db,
      [
        sqlight.text(branch_id),
        sqlight.blob(pack(types.ToolOutput(call_id, incomplete_tool_result))),
        sqlight.text(provider),
      ],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_conversation", "unpack")
fn unpack(bytes: BitArray) -> Result(types.Input, Nil)
