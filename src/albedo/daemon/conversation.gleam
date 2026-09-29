import albedo/daemon/events
import albedo/daemon/images
import albedo/daemon/mail
import albedo/daemon/note
import albedo/daemon/notice
import albedo/daemon/requests
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/extensions/python/cells as journal
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Info {
  Info(
    id: String,
    title: String,
    cwd: String,
    provider: String,
    model: String,
    protocol: types.Protocol,
    stage: Stage,
    last_assistant_at: Option(Int),
    effort: Option(String),
  )
}

/// Where a session's turn stood at its last commit. A daemon restart resumes
/// a session left at `Model` or `Tool`; `Interrupted` is a turn that ended
/// cancelled or failed and is not resumed.
pub type Stage {
  Idle
  Model
  Tool
  Interrupted
}

/// The stored and reported spelling of a stage.
pub fn stage_name(stage: Stage) -> String {
  case stage {
    Idle -> "idle"
    Model -> "model"
    Tool -> "tool"
    Interrupted -> "interrupted"
  }
}

/// An unrecognised stored stage is treated as a turn that did not finish.
fn parse_stage(name: String) -> Stage {
  case name {
    "idle" -> Idle
    "model" -> Model
    "tool" -> Tool
    _ -> Interrupted
  }
}

/// A restart picks up a turn that was waiting on the model or a tool.
pub fn resumable(stage: Stage) -> Bool {
  stage == Model || stage == Tool
}

pub fn initialise(store: store.Store) -> Result(Nil, String) {
  store.query(store, fn(db) {
    use _ <- result.try(store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,title TEXT NOT NULL DEFAULT 'new session',cwd TEXT NOT NULL,model TEXT NOT NULL,protocol TEXT NOT NULL,stage TEXT NOT NULL DEFAULT 'idle',provider TEXT,activity_seq INTEGER,last_assistant_at INTEGER,usage_model TEXT,usage_recorded_at INTEGER,usage_prompt_tokens INTEGER,usage_completion_tokens INTEGER,usage_cached_prompt_tokens INTEGER,usage_cache_creation_tokens INTEGER,effort TEXT); CREATE TABLE IF NOT EXISTS transcript(seq INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL REFERENCES sessions(id),payload BLOB NOT NULL,timestamp INTEGER,provider TEXT,thought_ms INTEGER); CREATE INDEX IF NOT EXISTS transcript_session ON transcript(session,seq);"
        <> images.schema
        <> requests.schema,
    ))
    use _ <- result.try(
      store.add_columns(db, "sessions", [
        #("provider", "TEXT"),
        #("title", "TEXT"),
        #("activity_seq", "INTEGER"),
        #("last_assistant_at", "INTEGER"),
        #("usage_model", "TEXT"),
        #("usage_recorded_at", "INTEGER"),
        #("usage_prompt_tokens", "INTEGER"),
        #("usage_completion_tokens", "INTEGER"),
        #("usage_cached_prompt_tokens", "INTEGER"),
        #("usage_cache_creation_tokens", "INTEGER"),
        #("usage_cache_write_5m_tokens", "INTEGER"),
        #("usage_cache_write_1h_tokens", "INTEGER"),
        #("usage_reasoning_tokens", "INTEGER"),
        #("effort", "TEXT"),
        #("pinned_instructions", "TEXT"),
        #("pinned_context", "BLOB"),
        #("pinned_head", "INTEGER"),
        #("name", "TEXT"),
      ]),
    )
    use _ <- result.try(
      store.add_columns(db, "transcript", [
        #("timestamp", "INTEGER"),
        #("provider", "TEXT"),
        #("thought_ms", "INTEGER"),
      ]),
    )
    use _ <- result.try(recover_sessions(db))
    store.exec(
      db,
      "CREATE INDEX IF NOT EXISTS sessions_activity ON sessions(activity_seq DESC)",
    )
  })
}

fn recovery_decoder() {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use activity_seq <- decode.field(2, decode.int)
  decode.success(#(id, title, activity_seq))
}

fn recover_sessions(db) -> Result(Nil, String) {
  use sessions <- result.try(store.rows(
    db,
    "SELECT id,COALESCE(title,''),COALESCE(activity_seq,-1) FROM sessions WHERE activity_seq IS NULL OR title IS NULL OR title=''",
    [],
    recovery_decoder(),
  ))
  list.try_each(sessions, fn(session) {
    let #(id, saved_title, activity_seq) = session
    use last_seq <- result.try(store.one(
      db,
      "SELECT COALESCE(MAX(seq),0) FROM transcript WHERE session=?",
      [sqlight.text(id)],
      decode.field(0, decode.int, decode.success),
      "could not recover session activity",
    ))
    use recovered_title <- result.try(
      case
        saved_title == ""
        || { saved_title == "new session" && activity_seq < 0 }
      {
        False -> Ok(saved_title)
        True ->
          store.rows(
            db,
            "SELECT payload FROM transcript WHERE session=? ORDER BY seq",
            [sqlight.text(id)],
            decode.field(0, decode.bit_array, decode.success),
          )
          |> result.map(fn(rows) {
            rows
            |> list.filter_map(unpack(_, unread))
            |> latest_user
            |> title_or_default
          })
      },
    )
    store.run(
      db,
      "UPDATE sessions SET title=?,activity_seq=CASE WHEN activity_seq IS NULL THEN ? ELSE activity_seq END WHERE id=?",
      [
        sqlight.text(recovered_title),
        sqlight.int(last_seq),
        sqlight.text(id),
      ],
    )
  })
}

pub fn assign_provider(
  store: store.Store,
  provider: String,
) -> Result(Nil, String) {
  store.write(
    store,
    "UPDATE sessions SET provider=? WHERE provider IS NULL OR provider=''",
    [sqlight.text(provider)],
  )
}

pub fn assign_session_provider(
  store: store.Store,
  id: String,
  provider: String,
) -> Result(Nil, String) {
  store.write(
    store,
    "UPDATE sessions SET provider=? WHERE id=? AND (provider IS NULL OR provider='')",
    [sqlight.text(provider), sqlight.text(id)],
  )
}

/// What `info_decoder` reads. A name someone gave the session outranks the
/// title its latest message suggests.
pub const info_columns = "id,COALESCE(NULLIF(name,''),NULLIF(title,''),'new session'),cwd,COALESCE(provider,''),model,protocol,stage,last_assistant_at,effort"

/// Decodes `info_columns`.
pub fn info_decoder() -> decode.Decoder(Info) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use cwd <- decode.field(2, decode.string)
  use provider <- decode.field(3, decode.string)
  use model <- decode.field(4, decode.string)
  use protocol <- decode.field(5, decode.string)
  use stage <- decode.field(6, decode.string)
  use last_assistant_at <- decode.field(7, decode.optional(decode.int))
  use effort <- decode.field(8, decode.optional(decode.string))
  decode.success(Info(
    id,
    title,
    cwd,
    provider,
    model,
    case protocol {
      "responses" -> types.Responses
      _ -> types.ChatCompletions
    },
    parse_stage(stage),
    last_assistant_at,
    effort,
  ))
}

pub fn list(store: store.Store) -> Result(List(Info), String) {
  store.read(
    store,
    "SELECT "
      <> info_columns
      <> " FROM sessions ORDER BY activity_seq DESC,rowid DESC",
    [],
    info_decoder(),
  )
}

pub fn get(store: store.Store, id: String) -> Result(Info, String) {
  store.query(store, read_info(_, id))
}

/// `get` inside a query the caller already holds.
pub fn read_info(db, id: String) -> Result(Info, String) {
  store.one(
    db,
    "SELECT " <> info_columns <> " FROM sessions WHERE id=?",
    [sqlight.text(id)],
    info_decoder(),
    "session not found",
  )
}

/// Give a session a name that its messages no longer retitle. A blank name
/// hands the title back to the latest message. Activity order is untouched.
pub fn rename(
  store: store.Store,
  id: String,
  name: String,
) -> Result(Info, String) {
  let name = case excerpt(name, 80) {
    "" -> None
    clean -> Some(clean)
  }
  store.query(store, fn(db) {
    use _ <- result.try(
      store.run(db, "UPDATE sessions SET name=? WHERE id=?", [
        sqlight.nullable(sqlight.text, name),
        sqlight.text(id),
      ]),
    )
    read_info(db, id)
  })
}

/// The name someone gave `id`, if any.
pub fn given_name(store: store.Store, id: String) -> Option(String) {
  store.read(
    store,
    "SELECT name FROM sessions WHERE id=? AND name<>''",
    [sqlight.text(id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.unwrap([])
  |> list.first
  |> option.from_result
}

/// Permanently remove a session and its dependent records in one transaction.
pub fn delete(store: store.Store, id: String) -> Result(Nil, String) {
  store.query(store, fn(db) {
    store.transaction(db, fn() {
      use hashes <- result.try(images.session_hashes(db, id))
      use tables <- result.try(store.rows(
        db,
        "SELECT name FROM sqlite_master WHERE type='table'",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      use cell_hashes <- result.try(case list.contains(tables, "cells") {
        True -> journal.session_hashes(db, id)
        False -> Ok([])
      })
      use _ <- result.try(
        list.try_each(
          [
            "transcript",
            "provider_requests",
            "schedules",
            "session_extensions",
            "rolling_compaction_state",
            "rolling_compaction_observation",
            "cells",
            "work",
          ],
          fn(table) {
            case list.contains(tables, table) {
              False -> Ok(Nil)
              True -> {
                use _ <- result.try(case table {
                  "cells" ->
                    store.run(
                      db,
                      "DELETE FROM cell_traces WHERE id IN (SELECT id FROM cells WHERE session=?)",
                      [sqlight.text(id)],
                    )
                  _ -> Ok(Nil)
                })
                store.run(db, "DELETE FROM " <> table <> " WHERE session=?", [
                  sqlight.text(id),
                ])
              }
            }
          },
        ),
      )
      use _ <- result.try(
        store.run(db, "DELETE FROM sessions WHERE id=?", [sqlight.text(id)]),
      )
      images.release(db, list.append(hashes, cell_hashes) |> list.unique)
    })
  })
}

pub fn create(store: store.Store, info: Info) -> Result(Nil, String) {
  store.write(
    store,
    "INSERT INTO sessions(id,title,cwd,provider,model,protocol,activity_seq,last_assistant_at,effort) SELECT ?,?,?,?,?,?,COALESCE(MAX(activity_seq),0)+1,?,? FROM sessions",
    [
      sqlight.text(info.id),
      sqlight.text(info.title),
      sqlight.text(info.cwd),
      sqlight.text(info.provider),
      sqlight.text(info.model),
      sqlight.text(protocol(info.protocol)),
      sqlight.nullable(sqlight.int, info.last_assistant_at),
      sqlight.nullable(sqlight.text, info.effort),
    ],
  )
}

pub fn protocol(protocol: types.Protocol) -> String {
  types.protocol_name(protocol)
}

pub fn title(text: String) -> String {
  case excerpt(text, 80) {
    "" -> "new session"
    clean -> clean
  }
}

/// One line of display-safe text: control and invisible characters become
/// spaces, runs of whitespace collapse, and anything past `limit` graphemes is
/// cut with an ellipsis.
pub fn excerpt(text: String, limit: Int) -> String {
  let assert Ok(space) = string.utf_codepoint(32)
  let clean =
    text
    |> string.to_utf_codepoints
    |> list.map(fn(codepoint) {
      let value = string.utf_codepoint_to_int(codepoint)
      case
        value <= 31
        || { value >= 127 && value <= 159 }
        || value == 173
        || value == 8203
        || { value >= 8206 && value <= 8207 }
        || { value >= 8232 && value <= 8238 }
        || { value >= 8288 && value <= 8297 }
        || value == 65_279
      {
        True -> space
        False -> codepoint
      }
    })
    |> string.from_utf_codepoints
    |> string.trim
    |> string.split(" ")
    |> list.filter(fn(part) { part != "" })
    |> string.join(" ")
  case string.length(clean) > limit {
    True -> string.slice(clean, 0, limit - 1) <> "…"
    False -> clean
  }
}

fn has_visible_assistant(inputs: List(types.Input)) -> Bool {
  list.any(inputs, fn(input) {
    option.is_some(events.visible_assistant_text(input))
  })
}

/// Whether one committed input is a row the model itself produced: an
/// assistant message or a replayed provider item, including a tool call. The
/// first such row of a commit is the transcript row that commit links to.
fn is_assistant_row(input: types.Input) -> Bool {
  case input {
    types.Replay(_) | types.Assistant(_) -> True
    _ -> False
  }
}

/// The newest message a person wrote. Notes are the daemon talking and mail
/// comes from other agents or outside, so neither names a session.
pub fn latest_user(inputs: List(types.Input)) -> Option(String) {
  list.fold(inputs, None, fn(latest, input) {
    case input {
      types.User(text) | types.UserImage(text, _) ->
        case notice.is_notice(text), note.parse(text), mail.is_mail(text) {
          False, None, False -> Some(text)
          _, _, _ -> latest
        }
      _ -> latest
    }
  })
}

/// The title `latest_user` suggests: its text, or the default title.
pub fn title_or_default(user: Option(String)) -> String {
  case user {
    Some(text) -> title(text)
    None -> "new session"
  }
}

pub fn load_entries(
  store: store.Store,
  id: String,
) -> Result(List(transcript.Entry), String) {
  load_sources(store, id)
  |> result.map(fn(rows) { list.map(rows, fn(row) { row.entry }) })
}

/// Read durable entries with their SQLite identities in chronological order.
pub fn load_sources(
  store: store.Store,
  id: String,
) -> Result(List(transcript.SourcedEntry), String) {
  use upper <- result.try(
    store.query(store, fn(db) {
      store.rows(
        db,
        "SELECT COALESCE(MAX(seq),-1) FROM transcript WHERE session=?",
        [sqlight.text(id)],
        decode.field(0, decode.int, decode.success),
      )
      |> result.map(fn(rows) { list.first(rows) |> result.unwrap(-1) })
    }),
  )
  load_source_pages(store, id, -1, upper, [])
}

/// Rows per store round trip. A transcript is read a page at a time so the
/// raw rows and their decoded entries are only ever live for one page, not
/// the whole transcript at once.
const load_page_rows = 128

fn load_source_pages(
  store: store.Store,
  id: String,
  after: Int,
  upper: Int,
  pages: List(List(transcript.SourcedEntry)),
) -> Result(List(transcript.SourcedEntry), String) {
  let read = images.reader(store)
  let page =
    store.query(store, fn(db) {
      use rows <- result.try(store.rows(
        db,
        "SELECT seq,payload,timestamp,provider,thought_ms FROM transcript WHERE session=? AND seq>? AND seq<=? ORDER BY seq LIMIT ?",
        [
          sqlight.text(id),
          sqlight.int(after),
          sqlight.int(upper),
          sqlight.int(load_page_rows),
        ],
        source_row(),
      ))
      use entries <- result.try(list.try_map(rows, sourced_entry(id, _, read)))
      Ok(#(entries, list.last(rows) |> result.map(fn(row) { row.0 })))
    })
  // New rows may land between pages; the captured upper bound keeps one view.
  case page {
    Error(error) -> Error(error)
    Ok(#(entries, Ok(last))) ->
      case list.length(entries) == load_page_rows {
        True -> load_source_pages(store, id, last, upper, [entries, ..pages])
        False -> Ok(list.flatten(list.reverse([entries, ..pages])))
      }
    Ok(#(entries, Error(_))) ->
      Ok(list.flatten(list.reverse([entries, ..pages])))
  }
}

/// A transcript row as the reads select it: seq, payload, timestamp,
/// provider, thought_ms.
fn source_row() -> decode.Decoder(
  #(Int, BitArray, Option(Int), Option(String), Option(Int)),
) {
  use seq <- decode.field(0, decode.int)
  use payload <- decode.field(1, decode.bit_array)
  use timestamp <- decode.field(2, decode.optional(decode.int))
  use provider <- decode.field(3, decode.optional(decode.string))
  use thought_ms <- decode.field(4, decode.optional(decode.int))
  decode.success(#(seq, payload, timestamp, provider, thought_ms))
}

/// One selected transcript row as its entry, keeping the row's source
/// reference and metadata. An undecodable payload is an invalid saved item.
fn sourced_entry(
  session: String,
  row: #(Int, BitArray, Option(Int), Option(String), Option(Int)),
  read: fn(String) -> Result(String, Nil),
) -> Result(transcript.SourcedEntry, String) {
  use input <- result.try(
    unpack(row.1, read)
    |> result.replace_error("invalid saved transcript item"),
  )
  Ok(transcript.SourcedEntry(
    transcript.SourceRef(session, row.0),
    transcript.Entry(input, row.2, row.3, row.4),
  ))
}

/// Rows read per step when a tail that starts on a tool result is widened.
const tail_step_rows = 32

/// At most this many extra rows widen a tail.
const tail_step_limit = 512

/// The newest `rows` transcript rows before `before` (exclusive; None reads
/// from the end), chronological. A page never starts on a tool result, whose
/// call would be on the page before: it is widened back to the nearest row
/// that is not one. The flag says whether older rows remain. Clients page
/// history with this instead of loading it whole.
pub fn load_tail(
  store: store.Store,
  id: String,
  before: Option(Int),
  rows: Int,
) -> Result(#(List(transcript.SourcedEntry), Bool), String) {
  let upper = option.unwrap(before, 9_223_372_036_854_775_807)
  use #(newest, full) <- result.try(read_before(
    store,
    id,
    upper,
    int.max(1, rows),
  ))
  widen(store, id, newest, full, 0)
}

fn widen(
  store: store.Store,
  id: String,
  entries: List(transcript.SourcedEntry),
  full: Bool,
  extra: Int,
) -> Result(#(List(transcript.SourcedEntry), Bool), String) {
  case entries {
    [] -> Ok(#([], False))
    [first, ..] ->
      case
        is_tool_result(first.entry.input) && full && extra < tail_step_limit
      {
        False -> Ok(#(entries, full))
        True -> {
          use #(older, older_full) <- result.try(read_before(
            store,
            id,
            first.source.seq,
            tail_step_rows,
          ))
          // Keep only what is needed: from the newest row that is not a
          // tool result. Older rows left out mean more remain.
          let skipped =
            older
            |> list.reverse
            |> list.take_while(fn(item) { is_tool_result(item.entry.input) })
            |> list.length
          case list.length(older) - skipped - 1 {
            head if head >= 0 ->
              Ok(#(
                list.append(list.drop(older, head), entries),
                head > 0 || older_full,
              ))
            _ ->
              widen(
                store,
                id,
                list.append(older, entries),
                older_full,
                extra + tail_step_rows,
              )
          }
        }
      }
  }
}

fn is_tool_result(input: types.Input) -> Bool {
  case input {
    types.ToolOutput(..) -> True
    _ -> False
  }
}

/// Up to `limit` rows before `upper`, chronological, and whether the read
/// was full (so older rows may remain).
fn read_before(
  store: store.Store,
  id: String,
  upper: Int,
  limit: Int,
) -> Result(#(List(transcript.SourcedEntry), Bool), String) {
  let read = images.reader(store)
  store.query(store, fn(db) {
    use rows <- result.try(store.rows(
      db,
      "SELECT seq,payload,timestamp,provider,thought_ms FROM transcript WHERE session=? AND seq<? ORDER BY seq DESC LIMIT ?",
      [sqlight.text(id), sqlight.int(upper), sqlight.int(limit)],
      source_row(),
    ))
    use entries <- result.try(
      list.try_map(list.reverse(rows), sourced_entry(id, _, read)),
    )
    Ok(#(entries, list.length(rows) == limit))
  })
}

/// The session's newest transcript sequence, or 0 when it has none.
pub fn last_seq(store: store.Store, id: String) -> Result(Int, String) {
  store.query(store, fn(db) {
    store.one(
      db,
      "SELECT COALESCE(MAX(seq),0) FROM transcript WHERE session=?",
      [sqlight.text(id)],
      decode.field(0, decode.int, decode.success),
      "session not found",
    )
  })
}

/// Resolve one reference by both session and sequence. A missing row is an
/// ordinary result (for example, a reference from a different database).
pub fn source(
  store: store.Store,
  reference: transcript.SourceRef,
) -> Result(Option(transcript.Entry), String) {
  let transcript.SourceRef(session, seq) = reference
  let read = images.reader(store)
  store.query(store, fn(db) {
    use rows <- result.try(store.rows(
      db,
      "SELECT seq,payload,timestamp,provider,thought_ms FROM transcript WHERE session=? AND seq=?",
      [sqlight.text(session), sqlight.int(seq)],
      source_row(),
    ))
    case rows {
      [] -> Ok(None)
      [row] ->
        sourced_entry(session, row, read)
        |> result.map(fn(entry) { Some(entry.entry) })
      _ -> Error("duplicate transcript source reference")
    }
  })
}

pub fn load(
  store: store.Store,
  id: String,
) -> Result(List(types.Input), String) {
  load_entries(store, id)
  |> result.map(fn(entries) { list.map(entries, fn(entry) { entry.input }) })
}

/// A prompt prefix a live session keeps while it is cached: the system
/// instructions and extension context blocks included in the system prompt.
pub type PinnedPrompt {
  PinnedPrompt(instructions: String, context: List(types.Input))
}

/// Atomically retain the old prompt prefix and append a short capability
/// notice to history. An existing pin wins across subsequent reloads.
pub fn append_capability_update(
  store: store.Store,
  id: String,
  pinned: PinnedPrompt,
  head: Int,
  update: String,
) -> Result(Int, String) {
  let timestamp = usage.now()
  store.query(store, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(
        store.run(
          db,
          "UPDATE sessions SET "
            <> "pinned_context=CASE WHEN pinned_instructions IS NULL THEN ? ELSE pinned_context END, "
            <> "pinned_head=CASE WHEN pinned_instructions IS NULL THEN ? ELSE pinned_head END, "
            <> "pinned_instructions=COALESCE(pinned_instructions, ?) WHERE id=?",
          [
            sqlight.blob(pack_list(pinned.context)),
            sqlight.int(head),
            sqlight.text(pinned.instructions),
            sqlight.text(id),
          ],
        ),
      )
      store.run(
        db,
        "INSERT INTO transcript(session,payload,timestamp) VALUES(?,?,?)",
        [
          sqlight.text(id),
          sqlight.blob(pack(types.User(update))),
          sqlight.int(timestamp),
        ],
      )
      |> result.replace(timestamp)
    })
  })
}

/// The session's pinned prompt, if a capability change left one. A pin whose
/// context cannot be decoded is ignored, so the session uses its current prompt.
pub fn prompt_pin(
  store: store.Store,
  id: String,
) -> Result(Option(#(PinnedPrompt, Int)), String) {
  store.query(store, fn(db) {
    use rows <- result.try(
      store.rows(
        db,
        "SELECT pinned_instructions, pinned_context, COALESCE(pinned_head, 0) FROM sessions WHERE id=?",
        [sqlight.text(id)],
        {
          use instructions <- decode.field(0, decode.optional(decode.string))
          use context <- decode.field(1, decode.optional(decode.bit_array))
          use head <- decode.field(2, decode.int)
          decode.success(#(instructions, context, head))
        },
      ),
    )
    case rows {
      [#(Some(instructions), Some(context), head)] ->
        Ok(
          unpack_list(context, images.reader(store))
          |> result.map(fn(context) {
            #(PinnedPrompt(instructions, context), head)
          })
          |> option.from_result,
        )
      [_] -> Ok(None)
      _ -> Error("session not found")
    }
  })
}

pub fn clear_prompt_pin(store: store.Store, id: String) -> Result(Nil, String) {
  store.write(
    store,
    "UPDATE sessions SET pinned_instructions=NULL, pinned_context=NULL, pinned_head=NULL WHERE id=?",
    [sqlight.text(id)],
  )
}

/// The entries inputs committed together become. A response's thinking time
/// goes on its first input that shows the thinking, so it is counted once.
pub fn entries(
  inputs: List(types.Input),
  timestamp: Option(Int),
  provider: Option(String),
  thought_ms: Option(Int),
) -> List(transcript.Entry) {
  let #(_, entries) =
    list.map_fold(inputs, thought_ms, fn(thought_ms, input) {
      let entry = transcript.Entry(input, timestamp, provider, _)
      case input {
        types.Replay(item) if thought_ms != None ->
          case events.thinking_text(item) {
            "" -> #(thought_ms, entry(None))
            _ -> #(None, entry(thought_ms))
          }
        _ -> #(thought_ms, entry(None))
      }
    })
  entries
}

/// Atomically appends transcript inputs and returns their shared daemon time.
/// Empty commits still update the session stage and return the operation time.
pub fn commit(
  store: store.Store,
  id: String,
  inputs: List(types.Input),
  stage: Stage,
) -> Result(Int, String) {
  commit_from(store, id, inputs, stage, None)
}

/// Appends inputs with the provider that produced or accepted them. Provider
/// provenance lets model preparation distinguish lossless replay from transfer.
pub fn commit_from(
  store: store.Store,
  id: String,
  inputs: List(types.Input),
  stage: Stage,
  provider: Option(String),
) -> Result(Int, String) {
  commit_with_letters(store, id, inputs, stage, provider, None, [])
  |> result.map(fn(committed) { committed.0 })
}

/// Appends a model response's inputs; `thought_ms`, how long the model
/// thought before it, is kept on the first that shows the thinking. Answers
/// the shared daemon time and the seq of the response's first assistant row,
/// so a recorded provider call can link to the transcript row it produced;
/// a commit with no assistant row links nothing.
pub fn commit_response(
  store: store.Store,
  id: String,
  inputs: List(types.Input),
  stage: Stage,
  provider: Option(String),
  thought_ms: Option(Int),
) -> Result(#(Int, Option(Int)), String) {
  commit_with_letters(store, id, inputs, stage, provider, thought_ms, [])
}

/// Letters and the inputs that carry them commit together, so a letter retried
/// after a crash cannot land in the transcript twice.
pub fn commit_letters(
  store: store.Store,
  id: String,
  inputs: List(types.Input),
  stage: Stage,
  provider: Option(String),
  letters: List(String),
) -> Result(Int, String) {
  commit_with_letters(store, id, inputs, stage, provider, None, letters)
  |> result.map(fn(committed) { committed.0 })
}

fn commit_with_letters(
  store: store.Store,
  id: String,
  inputs: List(types.Input),
  stage: Stage,
  provider: Option(String),
  thought_ms: Option(Int),
  letters: List(String),
) -> Result(#(Int, Option(Int)), String) {
  let timestamp = usage.now()
  let read = images.reader(store)
  store.query(store, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(mail.receive(db, id, letters))
      let advances_assistant = case has_visible_assistant(inputs) {
        True -> 1
        False -> 0
      }
      // The first assistant row of the commit, so a caller that recorded the
      // provider call behind it can link to the transcript row it produced.
      use linked <- result.try(
        entries(inputs, Some(timestamp), provider, thought_ms)
        |> list.try_fold(None, fn(linked, entry) {
          use input <- result.try(images.externalize(db, entry.input, read))
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO transcript(session,payload,timestamp,provider,thought_ms) VALUES(?,?,?,?,?)",
              [
                sqlight.text(id),
                sqlight.blob(pack(input)),
                sqlight.int(timestamp),
                sqlight.nullable(sqlight.text, provider),
                sqlight.nullable(sqlight.int, entry.thought_ms),
              ],
            ),
          )
          case linked, is_assistant_row(input) {
            None, True ->
              store.one(
                db,
                "SELECT last_insert_rowid()",
                [],
                decode.field(0, decode.int, decode.success),
                "committed row sequence",
              )
              |> result.map(Some)
            _, _ -> Ok(linked)
          }
        }),
      )
      // COALESCE keeps the old title when no new user message suggests one.
      store.run(
        db,
        "UPDATE sessions SET stage=?,title=COALESCE(?,title),activity_seq=(SELECT COALESCE(MAX(activity_seq),0)+1 FROM sessions),last_assistant_at=CASE WHEN ?=1 THEN unixepoch() ELSE last_assistant_at END WHERE id=?",
        [
          sqlight.text(stage_name(stage)),
          sqlight.nullable(sqlight.text, option.map(latest_user(inputs), title)),
          sqlight.int(advances_assistant),
          sqlight.text(id),
        ],
      )
      |> result.replace(linked)
    })
    |> result.map(fn(linked) { #(timestamp, linked) })
  })
}

fn usage_decoder() {
  use model <- decode.field(0, decode.optional(decode.string))
  use recorded_at <- decode.field(1, decode.optional(decode.int))
  use prompt <- decode.field(2, decode.optional(decode.int))
  use completion <- decode.field(3, decode.optional(decode.int))
  use cached <- decode.field(4, decode.optional(decode.int))
  use creation <- decode.field(5, decode.optional(decode.int))
  use write_5m <- decode.field(6, decode.optional(decode.int))
  use write_1h <- decode.field(7, decode.optional(decode.int))
  use reasoning <- decode.field(8, decode.optional(decode.int))
  case model, recorded_at, prompt, completion {
    None, None, None, None -> decode.success(None)
    Some(model), Some(recorded_at), None, None ->
      decode.success(Some(usage.Metadata(model, recorded_at, None)))
    Some(model), Some(recorded_at), Some(prompt), Some(completion) ->
      decode.success(
        Some(usage.Metadata(
          model,
          recorded_at,
          Some(usage.Tokens(
            prompt,
            completion,
            cached,
            creation,
            write_5m,
            write_1h,
            reasoning,
          )),
        )),
      )
    _, _, _, _ -> decode.failure(None, "consistent saved usage metadata")
  }
}

pub fn load_usage(
  store: store.Store,
  id: String,
) -> Result(Option(usage.Metadata), String) {
  store.query(store, fn(db) {
    store.one(
      db,
      "SELECT usage_model,usage_recorded_at,usage_prompt_tokens,usage_completion_tokens,usage_cached_prompt_tokens,usage_cache_creation_tokens,usage_cache_write_5m_tokens,usage_cache_write_1h_tokens,usage_reasoning_tokens FROM sessions WHERE id=?",
      [sqlight.text(id)],
      usage_decoder(),
      "session not found",
    )
  })
}

pub fn clear_usage(store: store.Store, id: String) -> Result(Nil, String) {
  store.write(
    store,
    "UPDATE sessions SET usage_model=NULL,usage_recorded_at=NULL,usage_prompt_tokens=NULL,usage_completion_tokens=NULL,usage_cached_prompt_tokens=NULL,usage_cache_creation_tokens=NULL,usage_cache_write_5m_tokens=NULL,usage_cache_write_1h_tokens=NULL,usage_reasoning_tokens=NULL WHERE id=?",
    [sqlight.text(id)],
  )
}

pub fn record_usage(
  store: store.Store,
  id: String,
  metadata: usage.Metadata,
) -> Result(Nil, String) {
  let usage.Metadata(model, recorded_at, tokens) = metadata
  let #(prompt, completion, cached, creation, write_5m, write_1h, reasoning) = case
    tokens
  {
    Some(usage.Tokens(
      prompt,
      completion,
      cached,
      creation,
      write_5m,
      write_1h,
      reasoning,
    )) -> #(
      Some(prompt),
      Some(completion),
      cached,
      creation,
      write_5m,
      write_1h,
      reasoning,
    )
    None -> #(None, None, None, None, None, None, None)
  }
  store.write(
    store,
    "UPDATE sessions SET usage_model=?,usage_recorded_at=?,usage_prompt_tokens=?,usage_completion_tokens=?,usage_cached_prompt_tokens=?,usage_cache_creation_tokens=?,usage_cache_write_5m_tokens=?,usage_cache_write_1h_tokens=?,usage_reasoning_tokens=? WHERE id=?",
    [
      sqlight.text(model),
      sqlight.int(recorded_at),
      sqlight.nullable(sqlight.int, prompt),
      sqlight.nullable(sqlight.int, completion),
      sqlight.nullable(sqlight.int, cached),
      sqlight.nullable(sqlight.int, creation),
      sqlight.nullable(sqlight.int, write_5m),
      sqlight.nullable(sqlight.int, write_1h),
      sqlight.nullable(sqlight.int, reasoning),
      sqlight.text(id),
    ],
  )
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_conversation", "unpack")
fn unpack(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, Nil)

/// For rows read only for their text, inside the store (which a real reader
/// would call back into).
fn unread(_hash: String) -> Result(String, Nil) {
  Error(Nil)
}

@external(erlang, "albedo_conversation", "pack_list")
fn pack_list(inputs: List(types.Input)) -> BitArray

@external(erlang, "albedo_conversation", "unpack_list")
fn unpack_list(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(List(types.Input), Nil)

pub fn set_effort(
  store: store.Store,
  id: String,
  effort: Option(String),
) -> Result(Nil, String) {
  store.write(store, "UPDATE sessions SET effort=? WHERE id=?", [
    sqlight.nullable(sqlight.text, effort),
    sqlight.text(id),
  ])
}

pub fn set_configuration(
  store: store.Store,
  id: String,
  provider: String,
  model: String,
  selected_protocol: types.Protocol,
  effort: Option(String),
) -> Result(Nil, String) {
  store.query(store, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(
        store.run(
          db,
          "UPDATE transcript SET provider=(SELECT provider FROM sessions WHERE id=?) WHERE session=? AND provider IS NULL",
          [sqlight.text(id), sqlight.text(id)],
        ),
      )
      store.run(
        db,
        "UPDATE sessions SET provider=?,model=?,protocol=?,effort=? WHERE id=?",
        [
          sqlight.text(provider),
          sqlight.text(model),
          sqlight.text(protocol(selected_protocol)),
          sqlight.nullable(sqlight.text, effort),
          sqlight.text(id),
        ],
      )
    })
  })
}

/// Workspace changes are serialized by the session actor with submissions.
pub fn set_workspace(
  store: store.Store,
  id: String,
  cwd: String,
) -> Result(Nil, String) {
  store.write(store, "UPDATE sessions SET cwd=? WHERE id=?", [
    sqlight.text(cwd),
    sqlight.text(id),
  ])
}
