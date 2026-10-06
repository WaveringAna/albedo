import albedo/daemon/family
import albedo/daemon/image_fit
import albedo/daemon/images
import albedo/daemon/mail
import albedo/daemon/message_content as events
import albedo/daemon/migrations/conversation_columns
import albedo/daemon/note
import albedo/daemon/notice
import albedo/daemon/operations
import albedo/daemon/requests
import albedo/daemon/session_configuration
import albedo/daemon/session_workspace
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/harness/cache_fade
import albedo/harness/extensions/python/cells as journal
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/int
import gleam/io
import gleam/json
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

pub type RunCompletion {
  RunCompletion(session_id: String, run_id: String, stage: Stage, state: String)
}

pub type Preview {
  Preview(text: String, transcript_count: Int, truncated: Bool)
}

pub type CapturedInfo {
  CapturedInfo(
    info: Info,
    pending_inputs: List(operations.Pending),
    input_order: Int,
    history_high_water: Int,
    created_at: Option(Int),
    activity_at: Option(Int),
    revision: Int,
    family: family.Facts,
    continuation_high_water: Int,
    automatic_name: String,
    configuration: session_configuration.Configuration,
    workspace_change: Option(session_workspace.Pending),
    preview: Preview,
    current_request: Option(mail.Request),
  )
}

/// One connection turn captures metadata and the transcript boundary. Another
/// session's writes cannot interleave these reads on the store owner.
pub fn capture(
  ledger: store.Store,
  id: String,
) -> Result(CapturedInfo, String) {
  store.query(ledger, fn(db) { capture_in(db, id) })
}

/// Capture using the caller's connection so a collection shares one boundary.
pub fn capture_in(
  db: sqlight.Connection,
  id: String,
) -> Result(CapturedInfo, String) {
  use info <- result.try(read_info(db, id))
  use metadata <- result.try(store.one(
    db,
    "SELECT input_order,COALESCE((SELECT MAX(seq) FROM transcript WHERE session=sessions.id),0),created_at,activity_at,config_revision,COALESCE((SELECT MAX(rowid) FROM continuation_markers WHERE session=sessions.id),0),preview_text,COALESCE(transcript_count,0),preview_truncated FROM sessions WHERE id=?",
    [sqlight.text(id)],
    {
      use order <- decode.field(0, decode.int)
      use high_water <- decode.field(1, decode.int)
      use created <- decode.field(2, decode.optional(decode.int))
      use activity <- decode.field(3, decode.optional(decode.int))
      use revision <- decode.field(4, decode.int)
      use continuation_high_water <- decode.field(5, decode.int)
      use preview_text <- decode.field(6, decode.string)
      use transcript_count <- decode.field(7, decode.int)
      use preview_truncated <- decode.field(8, sqlight.decode_bool())
      decode.success(#(
        order,
        high_water,
        created,
        activity,
        revision,
        continuation_high_water,
        Preview(preview_text, transcript_count, preview_truncated),
      ))
    },
    "session not found",
  ))
  use pending <- result.try(operations.pending_in(db, id))
  use configuration <- result.try(session_configuration.read_in(db, id))
  use workspace_change <- result.try(session_workspace.pending_in(db, id))
  use current_request <- result.try(mail.parent_request_in(db, id))
  Ok(CapturedInfo(
    info,
    pending,
    metadata.0,
    metadata.1,
    metadata.2,
    metadata.3,
    metadata.4,
    configuration.family,
    metadata.5,
    configuration.automatic_name,
    configuration,
    workspace_change,
    metadata.6,
    current_request,
  ))
}

/// The resolved configuration retained in an immutable creation receipt.
pub fn resolved_creation(info: Info) -> String {
  json.object([
    #("workspace", json.string(info.cwd)),
    #("provider_profile", json.string(info.provider)),
    #("model", json.string(info.model)),
    #("effort", json.nullable(info.effort, json.string)),
  ])
  |> json.to_string
}

pub type Creation {
  Creation(
    request: operations.Request,
    submitted: String,
    resolved: String,
    name: Option(String),
  )
}

pub type CreationRecord {
  CreationRecord(
    submitted: Option(String),
    resolved: Option(String),
    decided_at: Option(Int),
    deleted_at: Option(Int),
  )
}

pub type ChildCreation {
  ChildCreation(
    info: Info,
    creation: Creation,
    parent_id: String,
    name: String,
    input: operations.Request,
    payload: BitArray,
    task: mail.Letter,
  )
}

const creation_schema = "CREATE TABLE IF NOT EXISTS session_creation(session_id TEXT PRIMARY KEY,submitted TEXT,resolved TEXT,decided_at INTEGER,deleted_at INTEGER); CREATE INDEX IF NOT EXISTS session_creation_deleted ON session_creation(deleted_at) WHERE deleted_at IS NOT NULL;"

pub fn creation(
  ledger: store.Store,
  id: String,
) -> Result(Option(CreationRecord), String) {
  use rows <- result.try(
    store.read(
      ledger,
      "SELECT submitted,resolved,decided_at,deleted_at FROM session_creation WHERE session_id=?",
      [sqlight.text(id)],
      {
        use submitted <- decode.field(0, decode.optional(decode.string))
        use resolved <- decode.field(1, decode.optional(decode.string))
        use decided_at <- decode.field(2, decode.optional(decode.int))
        use deleted_at <- decode.field(3, decode.optional(decode.int))
        decode.success(CreationRecord(
          submitted,
          resolved,
          decided_at,
          deleted_at,
        ))
      },
    ),
  )
  Ok(list.first(rows) |> option.from_result)
}

pub fn prune_creation(ledger: store.Store) -> Result(Nil, String) {
  store.write(
    ledger,
    "DELETE FROM session_creation WHERE session_id IN (SELECT session_id FROM session_creation WHERE deleted_at IS NOT NULL AND deleted_at<? ORDER BY deleted_at LIMIT 128)",
    [sqlight.int(usage.now() - operations.retention_ms)],
  )
}

pub fn record_creation_in(
  db: sqlight.Connection,
  id: String,
  creation: Creation,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO session_creation(session_id,submitted,resolved,decided_at) VALUES(?,?,?,?)",
      [
        sqlight.text(id),
        sqlight.text(creation.submitted),
        sqlight.text(creation.resolved),
        sqlight.int(usage.now()),
      ],
    ),
  )
  store.run(
    db,
    "UPDATE sessions SET name=?,config_revision=config_revision+1 WHERE id=?",
    [
      sqlight.nullable(
        sqlight.text,
        option.then(creation.name, session_configuration.clean_name),
      ),
      sqlight.text(id),
    ],
  )
}

pub fn create_identified(
  ledger: store.Store,
  info: Info,
  creation: Creation,
) -> Result(operations.Receipt, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(creation_available_in(db, info.id))
      operations.admit_in(
        db,
        creation.request,
        201,
        creation.submitted,
        None,
        fn(db) {
          use _ <- result.try(create_in(db, info))
          record_creation_in(db, info.id, creation)
        },
      )
    })
  })
}

pub fn create_child_identified(
  ledger: store.Store,
  child: ChildCreation,
) -> Result(operations.Receipt, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(creation_available_in(db, child.info.id))
      operations.admit_in(
        db,
        child.creation.request,
        201,
        child.creation.submitted,
        None,
        fn(db) {
          use above <- result.try(session_configuration.read_in(
            db,
            child.parent_id,
          ))
          let info = Info(..child.info, cwd: above.workspace)
          let creation =
            Creation(..child.creation, resolved: resolved_creation(info))
          use _ <- result.try(
            case
              child.input.target == child.info.id
              && child.input.kind != "create"
              && child.task.id == child.input.id
              && child.task.recipient == child.info.id
              && child.task.sender == Some(child.parent_id)
              && child.task.kind == mail.Task
            {
              True -> Ok(Nil)
              False -> Error("invalid child task identity")
            },
          )
          use _ <- result.try(case operations.check_in(db, child.input) {
            Ok(None) -> Ok(Nil)
            Ok(Some(_)) -> Error("input_conflict")
            Error(error) -> Error(error)
          })
          use _ <- result.try(create_in(db, info))
          use _ <- result.try(family.link_in(
            db,
            child.info.id,
            child.parent_id,
            child.name,
          ))
          use _ <- result.try(record_creation_in(db, child.info.id, creation))
          use inserted <- result.try(mail.insert(
            db,
            child.task,
            mail.IdentifiedInput,
          ))
          use _ <- result.try(case inserted {
            True -> Ok(Nil)
            False -> Error("child task inbox is full")
          })
          operations.admit_pending_in(db, child.input, child.payload, 202, "{}")
          |> result.replace(Nil)
        },
      )
    })
  })
}

/// Creation preconditions apply before receipt recovery. A retained decision
/// describes the original creation; it cannot authorize replacing its resource.
pub fn creation_available_in(
  db: sqlight.Connection,
  id: String,
) -> Result(Nil, String) {
  use reason <- result.try(store.one(
    db,
    "SELECT CASE WHEN EXISTS(SELECT 1 FROM sessions WHERE id=?) THEN 'session_exists' WHEN EXISTS(SELECT 1 FROM session_creation WHERE session_id=? AND deleted_at IS NOT NULL) THEN 'session_deleted' ELSE '' END",
    [sqlight.text(id), sqlight.text(id)],
    decode.field(0, decode.string, decode.success),
    "creation lookup failed",
  ))
  case reason {
    "" -> Ok(Nil)
    _ -> Error(reason)
  }
}

/// Completion and receipt expiry start together. Transcript consumption alone
/// cannot retire an input whose worker is still running.
pub fn finish_turn(
  ledger: store.Store,
  completion: RunCompletion,
) -> Result(Int, String) {
  let now = usage.now()
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(operations.finish_turn_in(
        db,
        completion.run_id,
        completion.state,
        now,
      ))
      store.run(
        db,
        "UPDATE sessions SET stage=?,activity_at=?,activity_seq=(SELECT COALESCE(MAX(activity_seq),0)+1 FROM sessions) WHERE id=?",
        [
          sqlight.text(stage_name(completion.stage)),
          sqlight.int(now),
          sqlight.text(completion.session_id),
        ],
      )
      |> result.replace(now)
    })
  })
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
  use _ <- result.try(
    store.query(store, fn(db) {
      use _ <- result.try(store.exec(
        db,
        "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,title TEXT NOT NULL DEFAULT 'new session',cwd TEXT NOT NULL,model TEXT NOT NULL,protocol TEXT NOT NULL,stage TEXT NOT NULL DEFAULT 'idle',provider TEXT,activity_seq INTEGER,last_assistant_at INTEGER,usage_model TEXT,usage_recorded_at INTEGER,usage_prompt_tokens INTEGER,usage_completion_tokens INTEGER,usage_cached_prompt_tokens INTEGER,usage_cache_creation_tokens INTEGER,effort TEXT); CREATE TABLE IF NOT EXISTS transcript(seq INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL REFERENCES sessions(id),payload BLOB NOT NULL,timestamp INTEGER,provider TEXT,thought_ms INTEGER,row_class TEXT CHECK(row_class IN ('user','image_fit','other'))); CREATE INDEX IF NOT EXISTS transcript_session ON transcript(session,seq);"
          <> images.schema
          <> requests.schema
          <> operations.schema
          <> "CREATE TABLE IF NOT EXISTS transcript_calls(session TEXT NOT NULL REFERENCES sessions(id),call_id TEXT NOT NULL,seq INTEGER NOT NULL REFERENCES transcript(seq),name TEXT NOT NULL,call_index INTEGER NOT NULL,arguments_bytes INTEGER NOT NULL,PRIMARY KEY(session,call_id,seq)); CREATE INDEX IF NOT EXISTS transcript_calls_position ON transcript_calls(session,seq);"
          <> "CREATE TABLE IF NOT EXISTS transcript_traces(session TEXT NOT NULL REFERENCES sessions(id),cell_id TEXT NOT NULL,payload TEXT NOT NULL,PRIMARY KEY(session,cell_id));"
          <> "CREATE TABLE IF NOT EXISTS transcript_quarantine(seq INTEGER PRIMARY KEY,session TEXT NOT NULL REFERENCES sessions(id),payload BLOB NOT NULL,healed_at INTEGER NOT NULL);"
          <> creation_schema,
      ))
      use _ <- result.try(conversation_columns.apply(db))
      use _ <- result.try(session_configuration.initialise_in(db))
      use _ <- result.try(session_workspace.initialise_in(db))
      use _ <- result.try(
        store.add_columns(db, "sessions", [
          #("preview_text", "TEXT NOT NULL DEFAULT ''"),
          #("preview_truncated", "INTEGER NOT NULL DEFAULT 0"),
          #("preview_position", "INTEGER NOT NULL DEFAULT 0"),
          #("transcript_count", "INTEGER"),
        ]),
      )
      use _ <- result.try(
        store.add_columns(db, "transcript", [
          #("summary_indexed", "INTEGER NOT NULL DEFAULT 0"),
        ]),
      )
      use _ <- result.try(store.exec(
        db,
        "UPDATE sessions SET transcript_count=(SELECT COUNT(*) FROM transcript WHERE session=sessions.id) WHERE transcript_count IS NULL; CREATE TRIGGER IF NOT EXISTS transcript_summary_insert AFTER INSERT ON transcript BEGIN UPDATE sessions SET transcript_count=COALESCE(transcript_count,0)+1 WHERE id=NEW.session; END; CREATE TRIGGER IF NOT EXISTS transcript_summary_delete AFTER DELETE ON transcript BEGIN UPDATE sessions SET transcript_count=transcript_count-1 WHERE id=OLD.session; END",
      ))
      use _ <- result.try(store.exec(
        db,
        "DROP INDEX IF EXISTS transcript_calls_pending; DROP INDEX IF EXISTS transcript_summary_pending; CREATE INDEX IF NOT EXISTS transcript_entries_pending ON transcript(seq) WHERE calls_indexed=0 OR summary_indexed=0",
      ))
      use _ <- result.try(operations.initialise(db))
      use _ <- result.try(operations.abandon_unfinished(db))
      use _ <- result.try(
        store.run(
          db,
          "UPDATE sessions SET deletion_id=NULL WHERE deletion_id IS NOT NULL",
          [],
        ),
      )
      use _ <- result.try(recover_sessions(db))
      store.exec(
        db,
        "CREATE INDEX IF NOT EXISTS sessions_activity ON sessions(activity_seq DESC)",
      )
    }),
  )
  index_saved_entries(store)
}

@external(erlang, "albedo_context_snapshot", "page")
fn preview_prefix(text: String, index: Int, scalars: Int) -> String

/// Maintain bounded preview and call metadata in the source commit.
pub fn index_entry_in(
  db: sqlight.Connection,
  session: String,
  position: Int,
  input: types.Input,
) -> Result(Nil, String) {
  use _ <- result.try(
    events.calls(input)
    |> list.index_map(fn(call, index) { #(call, index) })
    |> list.try_each(fn(indexed) {
      let #(call, index) = indexed
      store.run(
        db,
        "INSERT OR IGNORE INTO transcript_calls(session,call_id,seq,name,call_index,arguments_bytes) VALUES(?,?,?,?,?,?)",
        [
          sqlight.text(session),
          sqlight.text(call.id),
          sqlight.int(position),
          sqlight.text(call.name),
          sqlight.int(index),
          sqlight.int(string.byte_size(
            transcript.argument_json(call.arguments) |> json.to_string,
          )),
        ],
      )
    }),
  )
  index_preview_in(db, session, position, input)
}

fn index_preview_in(
  db: sqlight.Connection,
  session: String,
  position: Int,
  input: types.Input,
) -> Result(Nil, String) {
  use _ <- result.try(case latest_user([input]) {
    None -> Ok(Nil)
    Some(text) -> {
      let prefix = preview_prefix(text, 0, 256)
      store.run(
        db,
        "UPDATE sessions SET preview_text=?,preview_truncated=?,preview_position=? WHERE id=? AND preview_position<?",
        [
          sqlight.text(prefix),
          sqlight.int(case prefix == text {
            True -> 0
            False -> 1
          }),
          sqlight.int(position),
          sqlight.text(session),
          sqlight.int(position),
        ],
      )
    }
  })
  store.run(
    db,
    "UPDATE transcript SET calls_indexed=1,summary_indexed=1 WHERE seq=? AND session=?",
    [sqlight.int(position), sqlight.text(session)],
  )
}

/// Replaces an unreadable saved row with a note saying so and moves its bytes
/// to `transcript_quarantine`; returns the note.
pub fn heal_in(
  db: sqlight.Connection,
  session: String,
  position: Int,
  payload: BitArray,
) -> Result(types.Input, String) {
  let note =
    types.User(
      "<system-note>A transcript item here could not be read and was set aside (row "
      <> int.to_string(position)
      <> ").</system-note>",
    )
  use _ <- result.try(
    store.run(
      db,
      "INSERT OR IGNORE INTO transcript_quarantine(seq,session,payload,healed_at) VALUES(?,?,?,unixepoch())",
      [sqlight.int(position), sqlight.text(session), sqlight.blob(payload)],
    ),
  )
  use _ <- result.try(
    store.run(db, "UPDATE transcript SET payload=?,row_class=? WHERE seq=?", [
      sqlight.blob(pack(note)),
      sqlight.text(transcript.row_class(note)),
      sqlight.int(position),
    ]),
  )
  io.println_error(
    "transcript row "
    <> int.to_string(position)
    <> " of session "
    <> session
    <> " could not be read; its bytes moved to transcript_quarantine",
  )
  Ok(note)
}

/// Index saved rows in bounded store turns. Indexed rows are skipped, so
/// an interrupted startup resumes its scan instead of loading the whole ledger.
fn index_saved_entries(ledger: store.Store) -> Result(Nil, String) {
  use count <- result.try(
    store.query(ledger, fn(db) {
      store.transaction(db, fn() {
        use rows <- result.try(
          store.rows(
            db,
            "SELECT seq,session,payload,calls_indexed FROM transcript WHERE calls_indexed=0 OR summary_indexed=0 ORDER BY seq LIMIT 128",
            [],
            {
              use position <- decode.field(0, decode.int)
              use session <- decode.field(1, decode.string)
              use payload <- decode.field(2, decode.bit_array)
              use calls_indexed <- decode.field(3, sqlight.decode_bool())
              decode.success(#(position, session, payload, calls_indexed))
            },
          ),
        )
        use _ <- result.try(
          list.try_each(rows, fn(row) {
            use input <- result.try(case unpack(row.2, unread) {
              Ok(input) -> Ok(input)
              Error(Nil) -> heal_in(db, row.1, row.0, row.2)
            })
            case row.3 {
              True -> index_preview_in(db, row.1, row.0, input)
              False -> index_entry_in(db, row.1, row.0, input)
            }
          }),
        )
        Ok(list.length(rows))
      })
    }),
  )
  case count == 128 {
    True -> index_saved_entries(ledger)
    False -> Ok(Nil)
  }
}

fn recovery_decoder() -> decode.Decoder(#(String, String, Int)) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use activity_seq <- decode.field(2, decode.int)
  decode.success(#(id, title, activity_seq))
}

fn recover_sessions(db: sqlight.Connection) -> Result(Nil, String) {
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

/// When each session last committed a turn, or was created, in milliseconds.
pub fn activity(store: store.Store) -> Result(List(#(String, Int)), String) {
  store.read(
    store,
    "SELECT id,COALESCE(activity_at,created_at,0) FROM sessions",
    [],
    {
      use id <- decode.field(0, decode.string)
      use at <- decode.field(1, decode.int)
      decode.success(#(id, at))
    },
  )
}

pub fn get(store: store.Store, id: String) -> Result(Info, String) {
  store.query(store, read_info(_, id))
}

/// `get` inside a query the caller already holds.
pub fn read_info(db: sqlight.Connection, id: String) -> Result(Info, String) {
  store.one(
    db,
    "SELECT " <> info_columns <> " FROM sessions WHERE id=?",
    [sqlight.text(id)],
    info_decoder(),
    "session not found",
  )
}

/// Remove a stopped, claimed member and its dependent records atomically.
pub fn delete_claimed(
  ledger: store.Store,
  id: String,
  claim: family.DeletionClaim,
  cleaners: List(fn(sqlight.Connection, String) -> Result(Nil, String)),
) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use token <- result.try(store.one(
        db,
        "SELECT deletion_id FROM sessions WHERE id=?",
        [sqlight.text(id)],
        decode.field(0, decode.optional(decode.string), decode.success),
        "session not found",
      ))
      use _ <- result.try(case token == Some(claim.token) {
        True -> Ok(Nil)
        False -> Error("deletion claim changed")
      })
      use children <- result.try(store.one(
        db,
        "SELECT COUNT(*) FROM session_family WHERE parent=?",
        [sqlight.text(id)],
        decode.field(0, decode.int, decode.success),
        "family unavailable",
      ))
      use _ <- result.try(case children {
        0 -> Ok(Nil)
        _ -> Error("a captured child could not be removed")
      })
      delete_in(db, id, cleaners)
    })
  })
}

fn delete_in(
  db: sqlight.Connection,
  id: String,
  cleaners: List(fn(sqlight.Connection, String) -> Result(Nil, String)),
) -> Result(Nil, String) {
  use _ <- result.try(operations.cancel_in(db, id))
  use _ <- result.try(operations.finish_deleted_session_in(db, id))
  use _ <- result.try(
    store.run(
      db,
      "INSERT INTO session_creation(session_id,deleted_at) VALUES(?,?) ON CONFLICT(session_id) DO UPDATE SET deleted_at=excluded.deleted_at",
      [sqlight.text(id), sqlight.int(usage.now())],
    ),
  )
  use hashes <- result.try(images.session_hashes(db, id))
  use tables <- result.try(store.rows(
    db,
    "SELECT name FROM sqlite_master WHERE type='table'",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  use _ <- result.try(case list.contains(tables, "session_family") {
    True -> family.changed_in(db, id)
    False -> Ok(Nil)
  })
  use cell_hashes <- result.try(case list.contains(tables, "cells") {
    True -> journal.session_hashes(db, id)
    False -> Ok([])
  })
  // Cell rows stay here: deleting them feeds the image reference count
  // released below, in this transaction.
  use _ <- result.try(
    list.try_each(
      [
        "transcript_calls",
        "transcript_traces",
        "transcript_quarantine",
        "transcript",
        "submission_events",
        "continuation_markers",
        "provider_requests",
        "session_extensions",
        "session_selection",
        "session_family",
        "cells",
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
  use _ <- result.try(list.try_each(cleaners, fn(clean) { clean(db, id) }))
  use _ <- result.try(
    store.run(db, "DELETE FROM sessions WHERE id=?", [sqlight.text(id)]),
  )
  images.release(db, list.append(hashes, cell_hashes) |> list.unique)
}

/// Trusted agent creation still commits membership with its session row.
pub fn create_child(
  ledger: store.Store,
  info: Info,
  parent: String,
  name: String,
) -> Result(#(Info, family.Member), String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use above <- result.try(session_configuration.read_in(db, parent))
      use _ <- result.try(family.available_in(db, parent))
      let info = Info(..info, cwd: above.workspace)
      use _ <- result.try(create_in(db, info))
      use member <- result.try(family.link_in(db, info.id, parent, name))
      Ok(#(info, member))
    })
  })
}

pub fn create(store: store.Store, info: Info) -> Result(Nil, String) {
  store.query(store, create_in(_, info))
}

fn create_in(db: sqlight.Connection, info: Info) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO sessions(id,title,cwd,provider,model,protocol,activity_seq,last_assistant_at,effort,created_at,activity_at) SELECT ?,?,?,?,?,?,COALESCE(MAX(activity_seq),0)+1,?,?,?,? FROM sessions",
    [
      sqlight.text(info.id),
      sqlight.text(info.title),
      sqlight.text(info.cwd),
      sqlight.text(info.provider),
      sqlight.text(info.model),
      sqlight.text(protocol(info.protocol)),
      sqlight.nullable(sqlight.int, info.last_assistant_at),
      sqlight.nullable(sqlight.text, info.effort),
      sqlight.int(usage.now()),
      sqlight.int(usage.now()),
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
  let clean = session_configuration.clean_name(text) |> option.unwrap("")
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

/// Captured append boundary shared by metadata and range reads.
pub type Snapshot {
  Snapshot(session: String, upper: Int, continuation_upper: Int)
}

pub fn snapshot(
  ledger: store.Store,
  session: String,
) -> Result(Snapshot, String) {
  store.read(
    ledger,
    "SELECT COALESCE((SELECT MAX(seq) FROM transcript WHERE session=?),0),COALESCE((SELECT MAX(rowid) FROM continuation_markers WHERE session=?),0)",
    [sqlight.text(session), sqlight.text(session)],
    {
      use upper <- decode.field(0, decode.int)
      use continuation_upper <- decode.field(1, decode.int)
      decode.success(Snapshot(session, upper, continuation_upper))
    },
  )
  |> result.try(fn(rows) {
    list.first(rows)
    |> result.replace_error("could not capture history boundary")
  })
}

pub type SourceStats {
  SourceStats(latest_user: Option(Int), uncovered: Bool, uncovered_users: Int)
}

pub fn source_stats(
  ledger: store.Store,
  snapshot: Snapshot,
  covered: Int,
) -> Result(SourceStats, String) {
  store.query(ledger, fn(db) {
    use latest <- result.try(store.one(
      db,
      "SELECT MAX(seq) FROM transcript WHERE session=? AND seq<=? AND row_class IN ('user','image_fit')",
      [sqlight.text(snapshot.session), sqlight.int(snapshot.upper)],
      decode.field(0, decode.optional(decode.int), decode.success),
      "transcript user boundary",
    ))
    use count <- result.try(store.one(
      db,
      "SELECT COUNT(*) FROM transcript WHERE session=? AND seq>? AND seq<=? AND row_class IN ('user','image_fit')",
      [
        sqlight.text(snapshot.session),
        sqlight.int(covered),
        sqlight.int(snapshot.upper),
      ],
      decode.field(0, decode.int, decode.success),
      "transcript user count",
    ))
    use uncovered <- result.try(store.one(
      db,
      "SELECT EXISTS(SELECT 1 FROM transcript WHERE session=? AND seq>? AND seq<=?)",
      [
        sqlight.text(snapshot.session),
        sqlight.int(covered),
        sqlight.int(snapshot.upper),
      ],
      decode.field(0, decode.int, decode.success),
      "transcript uncovered rows",
    ))
    Ok(SourceStats(latest, uncovered == 1, count))
  })
}

pub type FoldStep(a) {
  Continue(a)
  Stop(a)
}

type FitSchedule =
  List(#(Int, image_fit.Replacements))

/// Chronological range fold. Stop avoids reading another page; later image
/// fits up to the captured boundary still apply to earlier selected images.
pub fn fold_sources(
  ledger: store.Store,
  snapshot: Snapshot,
  first: Int,
  last: Int,
  acc: a,
  step: fn(a, transcript.SourcedEntry) -> FoldStep(a),
) -> Result(a, String) {
  use <- bool.guard(first > int.min(last, snapshot.upper), Ok(acc))
  let read = images.reader(ledger)
  use fits <- result.try(
    store.read(
      ledger,
      "SELECT seq,payload FROM transcript WHERE session=? AND seq>=? AND seq<=? AND row_class='image_fit' ORDER BY seq DESC",
      [
        sqlight.text(snapshot.session),
        sqlight.int(first),
        sqlight.int(snapshot.upper),
      ],
      {
        use seq <- decode.field(0, decode.int)
        use payload <- decode.field(1, decode.bit_array)
        decode.success(#(seq, payload))
      },
    ),
  )
  use #(schedule, replacements) <- result.try(
    list.try_fold(fits, #([], image_fit.replacements()), fn(acc, row) {
      use fit <- result.try(
        unpack_fit(row.1, read) |> result.replace_error("corrupt image fit row"),
      )
      let replacements = image_fit.add(acc.1, fit)
      Ok(#([#(row.0, acc.1), ..acc.0], replacements))
    }),
  )
  fold_source_pages(
    ledger,
    snapshot,
    first - 1,
    int.min(last, snapshot.upper),
    acc,
    step,
    schedule,
    replacements,
  )
}

fn fold_source_pages(
  ledger: store.Store,
  snapshot: Snapshot,
  after: Int,
  upper: Int,
  acc: a,
  step: fn(a, transcript.SourcedEntry) -> FoldStep(a),
  schedule: FitSchedule,
  replacements: image_fit.Replacements,
) -> Result(a, String) {
  let read = images.reader(ledger)
  use rows <- result.try(
    store.query(ledger, fn(db) {
      use rows <- result.try(store.rows(
        db,
        "SELECT seq,payload,timestamp,provider,thought_ms FROM transcript WHERE session=? AND seq>? AND seq<=? ORDER BY seq LIMIT 128",
        [sqlight.text(snapshot.session), sqlight.int(after), sqlight.int(upper)],
        source_row(),
      ))
      list.try_map(rows, sourced_entry(snapshot.session, _, read))
    }),
  )
  case list.reverse(rows) {
    [] -> Ok(acc)
    [last, ..] ->
      case fold_source_rows(rows, acc, step, schedule, replacements) {
        Stop(#(acc, _, _)) -> Ok(acc)
        Continue(#(acc, schedule, replacements)) -> {
          fold_source_pages(
            ledger,
            snapshot,
            last.source.seq,
            upper,
            acc,
            step,
            schedule,
            replacements,
          )
        }
      }
  }
}

fn fold_source_rows(
  rows: List(transcript.SourcedEntry),
  acc: a,
  step: fn(a, transcript.SourcedEntry) -> FoldStep(a),
  schedule: FitSchedule,
  replacements: image_fit.Replacements,
) -> FoldStep(#(a, FitSchedule, image_fit.Replacements)) {
  case rows {
    [] -> Continue(#(acc, schedule, replacements))
    [row, ..rest] -> {
      let #(schedule, replacements) =
        advance_fits(schedule, replacements, row.source.seq)
      let entry = row.entry
      let row =
        transcript.SourcedEntry(
          ..row,
          entry: transcript.Entry(
            ..entry,
            input: image_fit.apply_replacements(entry.input, replacements),
          ),
        )
      case step(acc, row) {
        Stop(acc) -> Stop(#(acc, schedule, replacements))
        Continue(acc) ->
          fold_source_rows(rest, acc, step, schedule, replacements)
      }
    }
  }
}

fn advance_fits(
  schedule: FitSchedule,
  replacements: image_fit.Replacements,
  seq: Int,
) -> #(FitSchedule, image_fit.Replacements) {
  case schedule {
    [#(at, next), ..rest] if at <= seq -> advance_fits(rest, next, seq)
    _ -> #(schedule, replacements)
  }
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

/// A loaded row, and the image fit it is when it is one.
type LoadedRow =
  #(transcript.SourcedEntry, Result(transcript.ImageFit, Nil))

/// Rows per store round trip. A transcript is read a page at a time so the
/// raw rows and their decoded entries are only ever live for one page, not
/// the whole transcript at once.
const load_page_rows = 128

fn load_source_pages(
  store: store.Store,
  id: String,
  after: Int,
  upper: Int,
  pages: List(List(LoadedRow)),
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
      use entries <- result.try(
        list.try_map(rows, fn(row) {
          sourced_entry(id, row, read)
          |> result.map(fn(entry) { #(entry, unpack_fit(row.1, read)) })
        }),
      )
      Ok(#(entries, list.last(rows) |> result.map(fn(row) { row.0 })))
    })
  // New rows may land between pages; the captured upper bound keeps one view.
  case page {
    Error(error) -> Error(error)
    Ok(#(entries, Ok(last))) ->
      case list.length(entries) == load_page_rows {
        True -> load_source_pages(store, id, last, upper, [entries, ..pages])
        False -> Ok(fitted(list.flatten(list.reverse([entries, ..pages]))))
      }
    Ok(#(entries, Error(_))) ->
      Ok(fitted(list.flatten(list.reverse([entries, ..pages]))))
  }
}

/// The entries with each image fit applied to every row before it, so a
/// history read up to any row is what the model was sent at that point.
fn fitted(rows: List(LoadedRow)) -> List(transcript.SourcedEntry) {
  let #(entries, _) =
    list.fold(list.reverse(rows), #([], image_fit.replacements()), fn(acc, row) {
      let #(entries, replacements) = acc
      let #(sourced, fit) = row
      let entry = sourced.entry
      let sourced =
        transcript.SourcedEntry(
          ..sourced,
          entry: transcript.Entry(
            ..entry,
            input: image_fit.apply_replacements(entry.input, replacements),
          ),
        )
      let replacements = case fit {
        Ok(fit) -> image_fit.add(replacements, fit)
        Error(_) -> replacements
      }
      #([sourced, ..entries], replacements)
    })
  entries
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
    transcript.Entry(
      input,
      row.2,
      row.3,
      row.4,
      Some(transcript.SourceRef(session, row.0)),
    ),
  ))
}

/// Decode a packed transcript row with lazy image payload reads.
/// Resolve a committed live tool result by its actual run/call identity.
/// Steering may append another row before the worker publishes completion;
/// a current high-water mark is therefore not a tool result identity.
pub fn tool_result_position(
  ledger: store.Store,
  session: String,
  run_id: String,
  call_id: String,
) -> Result(Option(Int), String) {
  store.query(ledger, fn(db) {
    use rows <- result.try(
      store.rows(
        db,
        "SELECT seq,payload FROM transcript WHERE session=? AND turn_id=? ORDER BY seq DESC LIMIT 200",
        [sqlight.text(session), sqlight.text(run_id)],
        {
          use position <- decode.field(0, decode.int)
          use payload <- decode.field(1, decode.bit_array)
          decode.success(#(position, payload))
        },
      ),
    )
    Ok(
      list.find_map(rows, fn(row) {
        case unpack(row.1, unread) {
          Ok(types.ToolOutput(id, _, _)) if id == call_id -> Ok(row.0)
          _ -> Error(Nil)
        }
      })
      |> option.from_result,
    )
  })
}

pub fn read_input(
  store: store.Store,
  payload: BitArray,
) -> Result(types.Input, Nil) {
  unpack(payload, images.reader(store))
}

pub type Direction {
  Before(position: Int)
  After(position: Int)
}

pub type Range {
  Range(
    snapshot: Snapshot,
    direction: Direction,
    limit: Int,
    continuation_after: Int,
  )
}

pub type TranscriptOwnership {
  TranscriptOwnership(
    position: Int,
    turn_id: Option(String),
    input_id: Option(String),
    display: Option(operations.Display),
    image_fit: Option(transcript.ImageFit),
    letter: Option(mail.Letter),
  )
}

pub type Continuation {
  Continuation(
    input_id: String,
    position: Int,
    display: operations.Display,
    timestamp: Option(Int),
    turn_id: Option(String),
    order: Int,
  )
}

fn continuation_decoder() -> decode.Decoder(Continuation) {
  use input_id <- decode.field(0, decode.string)
  use position <- decode.field(1, decode.int)
  use payload <- decode.field(2, decode.bit_array)
  use timestamp <- decode.field(3, decode.optional(decode.int))
  use turn_id <- decode.field(4, decode.optional(decode.string))
  use order <- decode.field(5, decode.int)
  decode.success(Continuation(
    input_id,
    position,
    operations.decode_display(payload),
    timestamp,
    turn_id,
    order,
  ))
}

/// A committed continuation remains readable after its input receipt expires.
pub fn continuation(
  ledger: store.Store,
  session: String,
  input_id: String,
) -> Result(Option(Continuation), String) {
  store.read(
    ledger,
    "SELECT operation_id,seq,payload,timestamp,turn_id,rowid FROM continuation_markers WHERE session=? AND operation_id=?",
    [sqlight.text(session), sqlight.text(input_id)],
    continuation_decoder(),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

pub type SourcePage {
  SourcePage(
    entries: List(transcript.SourcedEntry),
    ownership: List(TranscriptOwnership),
    has_more: Bool,
    has_older: Bool,
    has_newer: Bool,
    continuations: List(Continuation),
    more_continuations: Bool,
    traces: List(#(String, json.Json)),
    tools: List(ToolAssociation),
  )
}

pub type ToolAssociation {
  ToolAssociation(
    result_position: Int,
    call_id: String,
    name: String,
    call_position: Int,
    arguments: Option(String),
    arguments_bytes: Int,
    call_index: Int,
  )
}

fn tool_associations_in(
  db: sqlight.Connection,
  session: String,
  entries: List(transcript.SourcedEntry),
) -> Result(List(ToolAssociation), String) {
  let wanted =
    list.filter_map(entries, fn(entry) {
      case entry.entry.input {
        types.ToolOutput(call_id, _, _) -> Ok(#(entry.source.seq, call_id))
        _ -> Error(Nil)
      }
    })
  case wanted {
    [] -> Ok([])
    _ -> {
      let values = list.map(wanted, fn(_) { "(?,?)" }) |> string.join(",")
      let arguments =
        list.flat_map(wanted, fn(pair) {
          [sqlight.int(pair.0), sqlight.text(pair.1)]
        })
      use rows <- result.try(
        store.rows(
          db,
          "WITH wanted(position,call_id) AS (VALUES "
            <> values
            <> ") SELECT wanted.position,c.call_id,c.name,c.seq,c.arguments_bytes,c.call_index,CASE WHEN length(t.payload)<=8192 THEN t.payload ELSE NULL END FROM wanted JOIN transcript_calls c ON c.session=? AND c.call_id=wanted.call_id AND c.seq=(SELECT MAX(seq) FROM transcript_calls WHERE session=c.session AND call_id=c.call_id AND seq<wanted.position) JOIN transcript t ON t.seq=c.seq ORDER BY wanted.position",
          list.append(arguments, [sqlight.text(session)]),
          {
            use result_position <- decode.field(0, decode.int)
            use call_id <- decode.field(1, decode.string)
            use name <- decode.field(2, decode.string)
            use call_position <- decode.field(3, decode.int)
            use bytes <- decode.field(4, decode.int)
            use index <- decode.field(5, decode.int)
            use payload <- decode.field(6, decode.optional(decode.bit_array))
            decode.success(#(
              result_position,
              call_id,
              name,
              call_position,
              bytes,
              index,
              payload,
            ))
          },
        ),
      )
      list.try_map(rows, fn(row) {
        use arguments <- result.try(case row.6 {
          None -> Ok(None)
          Some(payload) -> {
            use input <- result.try(
              unpack(payload, unread)
              |> result.replace_error("invalid saved tool call"),
            )
            use call <- result.try(
              events.calls(input)
              |> list.find(fn(call) { call.id == row.1 })
              |> result.replace_error("saved tool call association is invalid"),
            )
            Ok(Some(call.arguments))
          }
        })
        Ok(ToolAssociation(row.0, row.1, row.2, row.3, arguments, row.4, row.5))
      })
    }
  }
}

/// Bound packed bodies before fetching them. The first row always advances
/// pagination, even when one durable entry alone exceeds the page budget.
const history_payload_bytes = 1_048_576

fn history_prefix(rows: List(#(Int, Int)), used: Int, count: Int) -> Int {
  case rows {
    [] -> count
    [#(_, bytes), ..rest] ->
      case count == 0 || used + bytes <= history_payload_bytes {
        True -> history_prefix(rest, used + bytes, count + 1)
        False -> count
      }
  }
}

/// Read a bounded chronological page through a captured append boundary.
/// Later commits cannot leak into a reset assembled from that snapshot.
pub fn read_range(
  ledger: store.Store,
  range: Range,
) -> Result(SourcePage, String) {
  let limit = int.min(200, int.max(1, range.limit))
  let #(predicate, ordering, position) = case range.direction {
    Before(position) -> #("seq<?", "DESC", position)
    After(position) -> #("seq>?", "ASC", position)
  }
  let read = images.reader(ledger)
  store.query(ledger, fn(db) {
    // Only integer metadata crosses the first query; large packed arguments,
    // results, and durable display bodies cannot multiply by the row limit.
    use sizes <- result.try(
      store.rows(
        db,
        "SELECT seq,length(payload)+COALESCE((SELECT length(payload) FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1),0) FROM transcript WHERE session=? AND seq<=? AND "
          <> predicate
          <> " ORDER BY seq "
          <> ordering
          <> " LIMIT ?",
        [
          sqlight.text(range.snapshot.session),
          sqlight.int(range.snapshot.upper),
          sqlight.int(position),
          sqlight.int(limit + 1),
        ],
        {
          use seq <- decode.field(0, decode.int)
          use bytes <- decode.field(1, decode.int)
          decode.success(#(seq, bytes))
        },
      ),
    )
    let admitted = history_prefix(list.take(sizes, limit), 0, 0)
    let more_entries = list.length(sizes) > admitted
    use rows <- result.try(
      store.rows(
        db,
        "SELECT seq,payload,timestamp,provider,thought_ms,turn_id,(SELECT operation_id FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1),(SELECT payload FROM submission_events WHERE session=transcript.session AND seq=transcript.seq LIMIT 1) FROM transcript WHERE session=? AND seq<=? AND "
          <> predicate
          <> " ORDER BY seq "
          <> ordering
          <> " LIMIT ?",
        [
          sqlight.text(range.snapshot.session),
          sqlight.int(range.snapshot.upper),
          sqlight.int(position),
          sqlight.int(admitted),
        ],
        {
          use row <- decode.then(source_row())
          use turn_id <- decode.field(5, decode.optional(decode.string))
          use input_id <- decode.field(6, decode.optional(decode.string))
          use display <- decode.field(7, decode.optional(decode.bit_array))
          decode.success(#(
            row,
            TranscriptOwnership(
              row.0,
              turn_id,
              input_id,
              option.map(display, operations.decode_display),
              unpack_fit(row.1, read) |> option.from_result,
              None,
            ),
          ))
        },
      ),
    )
    use letters <- result.try(mail.history_in(
      db,
      range.snapshot.session,
      list.filter_map(rows, fn(row) {
        case row.1.display {
          Some(display)
            if display.source == "mail" || display.source == "webhook"
          -> option.to_result(row.1.input_id, Nil)
          _ -> Error(Nil)
        }
      }),
    ))
    let rows =
      list.map(rows, fn(row) {
        let letter =
          list.find(letters, fn(letter) { Some(letter.id) == row.1.input_id })
          |> option.from_result
        #(row.0, TranscriptOwnership(..row.1, letter: letter))
      })
    let selected = rows
    let selected = case range.direction {
      Before(_) -> list.reverse(selected)
      After(_) -> selected
    }
    use entries <- result.try(
      list.try_map(selected, fn(row) {
        sourced_entry(range.snapshot.session, row.0, read)
      }),
    )
    let cell_ids =
      list.filter_map(entries, fn(entry) {
        case entry.entry.input {
          types.ToolOutput(_, output, _) ->
            json.parse(
              output,
              decode.field("cell_id", decode.string, decode.success),
            )
            |> result.replace_error(Nil)
          _ -> Error(Nil)
        }
      })
      |> list.unique
    use traces <- result.try(traces_in(db, range.snapshot.session, cell_ids))
    use tools <- result.try(tool_associations_in(
      db,
      range.snapshot.session,
      entries,
    ))
    let lower = case selected, range.direction, more_entries {
      [first, ..], Before(_), True -> first.0.0
      [_, ..], Before(_), False -> 0
      [_, ..], After(position), _ -> int.max(0, position)
      [], After(position), _ -> int.max(0, position)
      [], Before(_), _ -> 0
    }
    let upper = case list.last(selected) {
      Ok(last) -> last.0.0
      Error(_) ->
        case range.direction {
          Before(position) -> int.min(range.snapshot.upper, position - 1)
          After(_) -> range.snapshot.upper
        }
    }
    use continuation_sizes <- result.try(
      store.rows(
        db,
        "SELECT rowid,length(payload) FROM continuation_markers WHERE session=? AND seq>=? AND seq<=? AND rowid>? AND rowid<=? ORDER BY rowid LIMIT 201",
        [
          sqlight.text(range.snapshot.session),
          sqlight.int(lower),
          sqlight.int(upper),
          sqlight.int(range.continuation_after),
          sqlight.int(range.snapshot.continuation_upper),
        ],
        {
          use order <- decode.field(0, decode.int)
          use bytes <- decode.field(1, decode.int)
          decode.success(#(order, bytes))
        },
      ),
    )
    let admitted_continuations =
      history_prefix(list.take(continuation_sizes, 200), 0, 0)
    use continuations <- result.try(store.rows(
      db,
      "SELECT operation_id,seq,payload,timestamp,turn_id,rowid FROM continuation_markers WHERE session=? AND seq>=? AND seq<=? AND rowid>? AND rowid<=? ORDER BY rowid LIMIT ?",
      [
        sqlight.text(range.snapshot.session),
        sqlight.int(lower),
        sqlight.int(upper),
        sqlight.int(range.continuation_after),
        sqlight.int(range.snapshot.continuation_upper),
        sqlight.int(admitted_continuations),
      ],
      continuation_decoder(),
    ))
    use directions <- result.try(case selected {
      [] -> Ok(#(False, False))
      [first, ..] -> {
        let assert Ok(last) = list.last(selected)
        store.one(
          db,
          "SELECT EXISTS(SELECT 1 FROM transcript WHERE session=? AND seq<? AND seq<=?),EXISTS(SELECT 1 FROM transcript WHERE session=? AND seq>? AND seq<=?)",
          [
            sqlight.text(range.snapshot.session),
            sqlight.int(first.0.0),
            sqlight.int(range.snapshot.upper),
            sqlight.text(range.snapshot.session),
            sqlight.int(last.0.0),
            sqlight.int(range.snapshot.upper),
          ],
          {
            use older <- decode.field(0, sqlight.decode_bool())
            use newer <- decode.field(1, sqlight.decode_bool())
            decode.success(#(older, newer))
          },
          "history navigation unavailable",
        )
      }
    })
    Ok(SourcePage(
      entries,
      list.map(selected, fn(row) { row.1 }),
      more_entries,
      directions.0,
      directions.1,
      list.take(continuations, 200),
      list.length(continuation_sizes) > admitted_continuations,
      traces,
      tools,
    ))
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
      use position <- result.try(store.one(
        db,
        "INSERT INTO transcript(session,payload,timestamp,row_class) VALUES(?,?,?,'user') RETURNING seq",
        [
          sqlight.text(id),
          sqlight.blob(pack(types.User(update))),
          sqlight.int(timestamp),
        ],
        decode.field(0, decode.int, decode.success),
        "pinned prompt update was not committed",
      ))
      index_entry_in(db, id, position, types.User(update))
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

/// The prompt the model last knew the session by, sent or announced in a
/// capability note, and a hash of the tools offered beside it. A prompt
/// prepared afresh after a restart or an unload is compared against it.
pub fn known_prompt(
  store: store.Store,
  id: String,
) -> Result(Option(#(PinnedPrompt, String)), String) {
  use rows <- result.try(
    store.read(
      store,
      "SELECT known_instructions, known_context, known_tools FROM sessions WHERE id=? AND known_instructions IS NOT NULL",
      [sqlight.text(id)],
      {
        use instructions <- decode.field(0, decode.string)
        use context <- decode.field(1, decode.bit_array)
        use tools <- decode.field(2, decode.string)
        decode.success(#(instructions, context, tools))
      },
    ),
  )
  case rows {
    [#(instructions, context, tools)] ->
      Ok(
        unpack_list(context, images.reader(store))
        |> result.map(fn(context) {
          #(PinnedPrompt(instructions, context), tools)
        })
        |> option.from_result,
      )
    _ -> Ok(None)
  }
}

pub fn remember_prompt(
  store: store.Store,
  id: String,
  prompt: PinnedPrompt,
  tools: String,
) -> Result(Nil, String) {
  store.write(
    store,
    "UPDATE sessions SET known_instructions=?, known_context=?, known_tools=? WHERE id=?",
    [
      sqlight.text(prompt.instructions),
      sqlight.blob(pack_list(prompt.context)),
      sqlight.text(tools),
      sqlight.text(id),
    ],
  )
}

/// How many original inputs the session's last prepared request had
/// compaction stand in for: the baseline a pin made after a restart starts at.
pub fn prepared_head(
  store: store.Store,
  id: String,
) -> Result(Option(Int), String) {
  store.read(
    store,
    "SELECT prepared_head FROM sessions WHERE id=? AND prepared_head IS NOT NULL",
    [sqlight.text(id)],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(rows) { list.first(rows) |> option.from_result })
}

pub fn save_prepared_head(
  store: store.Store,
  id: String,
  head: Int,
) -> Result(Nil, String) {
  store.write(store, "UPDATE sessions SET prepared_head=? WHERE id=?", [
    sqlight.int(head),
    sqlight.text(id),
  ])
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
      let entry = transcript.Entry(input, timestamp, provider, _, None)
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

/// Appends image fit rows (see transcript.ImageFit), storing each fitted
/// payload, and returns their shared daemon time.
pub fn commit_fits(
  store: store.Store,
  id: String,
  fits: List(transcript.ImageFit),
  provider: String,
) -> Result(Int, String) {
  let timestamp = usage.now()
  store.query(store, fn(db) {
    store.transaction(db, fn() {
      list.try_each(fits, fn(fit) {
        use stored <- result.try(images.store_images(db, [fit.image]))
        let assert [image] = stored
        store.run(
          db,
          "INSERT INTO transcript(session,payload,timestamp,provider,row_class) VALUES(?,?,?,?,'image_fit')",
          [
            sqlight.text(id),
            sqlight.blob(pack_fit(fit.note, fit.source, image)),
            sqlight.int(timestamp),
            sqlight.text(provider),
          ],
        )
      })
      |> result.replace(timestamp)
    })
  })
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
  commit_with_letters(store, id, inputs, stage, provider, None, [], [], None)
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
  run_id: String,
) -> Result(#(Int, Option(Int)), String) {
  commit_with_letters(
    store,
    id,
    inputs,
    stage,
    provider,
    thought_ms,
    [],
    [],
    Some(#(run_id, None)),
  )
}

/// Input consumption and turn membership commit with the model input.
pub fn commit_operations(
  ledger: store.Store,
  id: String,
  inputs: List(types.Input),
  stage: Stage,
  provider: Option(String),
  letters: List(String),
  commits: List(operations.Commit),
  turn_id: String,
  workspace: String,
) -> Result(Int, String) {
  commit_with_letters(
    ledger,
    id,
    inputs,
    stage,
    provider,
    None,
    letters,
    commits,
    Some(#(turn_id, Some(workspace))),
  )
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
  commits: List(operations.Commit),
  turn: Option(#(String, Option(String))),
) -> Result(#(Int, Option(Int)), String) {
  let timestamp = usage.now()
  let turn_id = option.map(turn, fn(value) { value.0 })
  let read = images.reader(store)
  store.query(store, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(case turn {
        None -> Ok(Nil)
        Some(#(run, workspace)) ->
          operations.begin_turn_in(db, id, run, timestamp, workspace)
      })
      use _ <- result.try(mail.receive(db, id, letters))
      use previous_seq <- result.try(store.one(
        db,
        "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='transcript'),0)",
        [],
        decode.field(0, decode.int, decode.success),
        "transcript boundary",
      ))
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
              "INSERT INTO transcript(session,payload,timestamp,provider,thought_ms,row_class,turn_id) VALUES(?,?,?,?,?,?,?)",
              [
                sqlight.text(id),
                sqlight.blob(pack(input)),
                sqlight.int(timestamp),
                sqlight.nullable(sqlight.text, provider),
                sqlight.nullable(sqlight.int, entry.thought_ms),
                sqlight.text(transcript.row_class(input)),
                sqlight.nullable(sqlight.text, turn_id),
              ],
            ),
          )
          use position <- result.try(store.one(
            db,
            "SELECT last_insert_rowid()",
            [],
            decode.field(0, decode.int, decode.success),
            "committed row sequence",
          ))
          use _ <- result.try(index_entry_in(db, id, position, input))
          case linked, is_assistant_row(input) {
            None, True -> Ok(Some(position))
            _, _ -> Ok(linked)
          }
        }),
      )
      use seq <- result.try(store.one(
        db,
        "SELECT COALESCE(MAX(seq),0) FROM transcript WHERE session=?",
        [sqlight.text(id)],
        decode.field(0, decode.int, decode.success),
        "committed input sequence",
      ))
      use _ <- result.try(operations.committed(
        db,
        id,
        commits,
        previous_seq + 1,
        seq,
        turn_id,
      ))
      // COALESCE keeps the old title when no new user message suggests one.
      store.run(
        db,
        "UPDATE sessions SET stage=?,title=COALESCE(?,title),activity_at=?,activity_seq=(SELECT COALESCE(MAX(activity_seq),0)+1 FROM sessions),last_assistant_at=CASE WHEN ?=1 THEN unixepoch() ELSE last_assistant_at END WHERE id=?",
        [
          sqlight.text(stage_name(stage)),
          sqlight.nullable(sqlight.text, option.map(latest_user(inputs), title)),
          sqlight.int(timestamp),
          sqlight.int(advances_assistant),
          sqlight.text(id),
        ],
      )
      |> result.replace(linked)
    })
    |> result.map(fn(linked) { #(timestamp, linked) })
  })
}

fn usage_decoder() -> decode.Decoder(Option(usage.Metadata)) {
  use model <- decode.field(0, decode.optional(decode.string))
  use recorded_at <- decode.field(1, decode.optional(decode.int))
  use prompt <- decode.field(2, decode.optional(decode.int))
  use completion <- decode.field(3, decode.optional(decode.int))
  use cached <- decode.field(4, decode.optional(decode.int))
  use creation <- decode.field(5, decode.optional(decode.int))
  use write_5m <- decode.field(6, decode.optional(decode.int))
  use write_1h <- decode.field(7, decode.optional(decode.int))
  use reasoning <- decode.field(8, decode.optional(decode.int))
  use cache <- decode.field(9, decode.optional(decode.string))
  // A fading that no longer parses only loses the footer's countdown.
  let cache =
    option.then(cache, fn(stored) {
      json.parse(stored, cache_fade.decoder()) |> option.from_result
    })
  case model, recorded_at, prompt, completion {
    None, None, None, None -> decode.success(None)
    Some(model), Some(recorded_at), None, None ->
      decode.success(Some(usage.Metadata(model, recorded_at, None, cache)))
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
          cache,
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
      "SELECT usage_model,usage_recorded_at,usage_prompt_tokens,usage_completion_tokens,usage_cached_prompt_tokens,usage_cache_creation_tokens,usage_cache_write_5m_tokens,usage_cache_write_1h_tokens,usage_reasoning_tokens,usage_cache FROM sessions WHERE id=?",
      [sqlight.text(id)],
      usage_decoder(),
      "session not found",
    )
  })
}

pub fn clear_usage(store: store.Store, id: String) -> Result(Nil, String) {
  store.write(
    store,
    "UPDATE sessions SET usage_model=NULL,usage_recorded_at=NULL,usage_prompt_tokens=NULL,usage_completion_tokens=NULL,usage_cached_prompt_tokens=NULL,usage_cache_creation_tokens=NULL,usage_cache_write_5m_tokens=NULL,usage_cache_write_1h_tokens=NULL,usage_reasoning_tokens=NULL,usage_cache=NULL WHERE id=?",
    [sqlight.text(id)],
  )
}

pub fn record_usage(
  store: store.Store,
  id: String,
  metadata: usage.Metadata,
) -> Result(Nil, String) {
  let usage.Metadata(model, recorded_at, tokens, cache) = metadata
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
  let cache =
    option.map(cache, fn(fade) { json.to_string(cache_fade.to_json(fade)) })
  store.write(
    store,
    "UPDATE sessions SET usage_model=?,usage_recorded_at=?,usage_prompt_tokens=?,usage_completion_tokens=?,usage_cached_prompt_tokens=?,usage_cache_creation_tokens=?,usage_cache_write_5m_tokens=?,usage_cache_write_1h_tokens=?,usage_reasoning_tokens=?,usage_cache=? WHERE id=?",
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
      sqlight.nullable(sqlight.text, cache),
      sqlight.text(id),
    ],
  )
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_conversation", "pack_fit")
fn pack_fit(note: String, source: String, image: types.Image) -> BitArray

@external(erlang, "albedo_conversation", "unpack_fit")
fn unpack_fit(
  bytes: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(transcript.ImageFit, Nil)

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
  store.write(
    store,
    "UPDATE sessions SET effort=?,config_revision=config_revision+1 WHERE id=?",
    [
      sqlight.nullable(sqlight.text, effort),
      sqlight.text(id),
    ],
  )
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
        "UPDATE sessions SET provider=?,model=?,protocol=?,effort=?,config_revision=config_revision+1 WHERE id=?",
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

/// Fork-owned observations survive deletion of the original runtime journal.
pub fn traces_in(
  db: sqlight.Connection,
  session: String,
  ids: List(String),
) -> Result(List(#(String, json.Json)), String) {
  case ids {
    [] -> Ok([])
    _ -> {
      let placeholders = list.map(ids, fn(_) { "?" }) |> string.join(",")
      use snapshots <- result.try(
        store.rows(
          db,
          "SELECT cell_id,payload FROM transcript_traces WHERE session=? AND cell_id IN ("
            <> placeholders
            <> ")",
          [sqlight.text(session), ..list.map(ids, sqlight.text)],
          {
            use id <- decode.field(0, decode.string)
            use payload <- decode.field(1, decode.string)
            decode.success(#(id, payload))
          },
        ),
      )
      use captured <- result.try(
        list.try_map(snapshots, fn(row) {
          json.parse(row.1, decode.dynamic)
          |> result.map(fn(value) { #(row.0, types.encode_value(value)) })
          |> result.replace_error("invalid saved transcript trace")
        }),
      )
      let missing =
        list.filter(ids, fn(id) { !list.any(captured, fn(row) { row.0 == id }) })
      use live <- result.try(journal.traces_in(db, missing))
      Ok(list.append(captured, live))
    }
  }
}
