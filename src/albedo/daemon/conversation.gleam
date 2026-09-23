import albedo/daemon/events
import albedo/daemon/store
import albedo/daemon/transcript
import albedo/daemon/usage
import albedo/openai_api/types
import gleam/dynamic/decode
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
    use _ <- result.try(
      sqlight.exec(
        "CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,title TEXT NOT NULL DEFAULT 'new session',cwd TEXT NOT NULL,model TEXT NOT NULL,protocol TEXT NOT NULL,stage TEXT NOT NULL DEFAULT 'idle',provider TEXT,activity_seq INTEGER,last_assistant_at INTEGER,usage_model TEXT,usage_recorded_at INTEGER,usage_prompt_tokens INTEGER,usage_completion_tokens INTEGER,usage_cached_prompt_tokens INTEGER); CREATE TABLE IF NOT EXISTS transcript(seq INTEGER PRIMARY KEY AUTOINCREMENT,session TEXT NOT NULL REFERENCES sessions(id),payload BLOB NOT NULL,timestamp INTEGER,provider TEXT); CREATE INDEX IF NOT EXISTS transcript_session ON transcript(session,seq);",
        db,
      )
      |> result.map_error(fn(e) { e.message }),
    )
    use columns <- result.try(
      sqlight.query(
        "PRAGMA table_info(sessions)",
        db,
        [],
        decode.field(1, decode.string, decode.success),
      )
      |> result.map_error(fn(e) { e.message }),
    )
    use _ <- result.try(case list.contains(columns, "provider") {
      True -> Ok(Nil)
      False ->
        sqlight.exec("ALTER TABLE sessions ADD COLUMN provider TEXT", db)
        |> result.map_error(fn(e) { e.message })
    })
    use _ <- result.try(case list.contains(columns, "title") {
      True -> Ok(Nil)
      False ->
        sqlight.exec("ALTER TABLE sessions ADD COLUMN title TEXT", db)
        |> result.map_error(fn(e) { e.message })
    })
    use _ <- result.try(case list.contains(columns, "activity_seq") {
      True -> Ok(Nil)
      False ->
        sqlight.exec("ALTER TABLE sessions ADD COLUMN activity_seq INTEGER", db)
        |> result.map_error(fn(e) { e.message })
    })
    use _ <- result.try(case list.contains(columns, "last_assistant_at") {
      True -> Ok(Nil)
      False ->
        sqlight.exec(
          "ALTER TABLE sessions ADD COLUMN last_assistant_at INTEGER",
          db,
        )
        |> result.map_error(fn(e) { e.message })
    })
    use _ <- result.try(
      [
        #("usage_model", "TEXT"),
        #("usage_recorded_at", "INTEGER"),
        #("usage_prompt_tokens", "INTEGER"),
        #("usage_completion_tokens", "INTEGER"),
        #("usage_cached_prompt_tokens", "INTEGER"),
      ]
      |> list.try_each(fn(column) {
        case list.contains(columns, column.0) {
          True -> Ok(Nil)
          False ->
            sqlight.exec(
              "ALTER TABLE sessions ADD COLUMN " <> column.0 <> " " <> column.1,
              db,
            )
            |> result.map_error(fn(e) { e.message })
        }
      }),
    )
    use transcript_columns <- result.try(
      sqlight.query(
        "PRAGMA table_info(transcript)",
        db,
        [],
        decode.field(1, decode.string, decode.success),
      )
      |> result.map_error(fn(e) { e.message }),
    )
    use _ <- result.try(case list.contains(transcript_columns, "timestamp") {
      True -> Ok(Nil)
      False ->
        sqlight.exec("ALTER TABLE transcript ADD COLUMN timestamp INTEGER", db)
        |> result.map_error(fn(e) { e.message })
    })
    use _ <- result.try(case list.contains(transcript_columns, "provider") {
      True -> Ok(Nil)
      False ->
        sqlight.exec("ALTER TABLE transcript ADD COLUMN provider TEXT", db)
        |> result.map_error(fn(e) { e.message })
    })
    use _ <- result.try(recover_sessions(db))
    sqlight.exec(
      "CREATE INDEX IF NOT EXISTS sessions_activity ON sessions(activity_seq DESC)",
      db,
    )
    |> result.map_error(fn(e) { e.message })
  })
}

fn recovery_decoder() {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use activity_seq <- decode.field(2, decode.int)
  decode.success(#(id, title, activity_seq))
}

fn recover_sessions(db) -> Result(Nil, String) {
  use sessions <- result.try(
    sqlight.query(
      "SELECT id,COALESCE(title,''),COALESCE(activity_seq,-1) FROM sessions WHERE activity_seq IS NULL OR title IS NULL OR title=''",
      db,
      [],
      recovery_decoder(),
    )
    |> result.map_error(fn(e) { e.message }),
  )
  list.try_each(sessions, fn(session) {
    let #(id, saved_title, activity_seq) = session
    use last_seq <- result.try(
      sqlight.query(
        "SELECT COALESCE(MAX(seq),0) FROM transcript WHERE session=?",
        db,
        [sqlight.text(id)],
        decode.field(0, decode.int, decode.success),
      )
      |> result.map_error(fn(e) { e.message })
      |> result.try(fn(rows) {
        list.first(rows)
        |> result.replace_error("could not recover session activity")
      }),
    )
    use recovered_title <- result.try(
      case
        saved_title == ""
        || { saved_title == "new session" && activity_seq < 0 }
      {
        False -> Ok(saved_title)
        True ->
          sqlight.query(
            "SELECT payload FROM transcript WHERE session=? ORDER BY seq",
            db,
            [sqlight.text(id)],
            decode.field(0, decode.bit_array, decode.success),
          )
          |> result.map_error(fn(e) { e.message })
          |> result.map(fn(rows) {
            rows
            |> list.filter_map(unpack)
            |> latest_user
            |> title_or_default
          })
      },
    )
    sqlight.query(
      "UPDATE sessions SET title=?,activity_seq=CASE WHEN activity_seq IS NULL THEN ? ELSE activity_seq END WHERE id=?",
      db,
      [
        sqlight.text(recovered_title),
        sqlight.int(last_seq),
        sqlight.text(id),
      ],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn assign_provider(
  store: store.Store,
  provider: String,
) -> Result(Nil, String) {
  store.query(store, fn(db) {
    sqlight.query(
      "UPDATE sessions SET provider=? WHERE provider IS NULL OR provider=''",
      db,
      [sqlight.text(provider)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn assign_session_provider(
  store: store.Store,
  id: String,
  provider: String,
) -> Result(Nil, String) {
  store.query(store, fn(db) {
    sqlight.query(
      "UPDATE sessions SET provider=? WHERE id=? AND (provider IS NULL OR provider='')",
      db,
      [sqlight.text(provider), sqlight.text(id)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

/// Decodes the `id,title,cwd,provider,model,protocol,stage,last_assistant_at` columns.
pub fn info_decoder() -> decode.Decoder(Info) {
  use id <- decode.field(0, decode.string)
  use title <- decode.field(1, decode.string)
  use cwd <- decode.field(2, decode.string)
  use provider <- decode.field(3, decode.string)
  use model <- decode.field(4, decode.string)
  use protocol <- decode.field(5, decode.string)
  use stage <- decode.field(6, decode.string)
  use last_assistant_at <- decode.field(7, decode.optional(decode.int))
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
  ))
}

pub fn list(store: store.Store) -> Result(List(Info), String) {
  store.query(store, fn(db) {
    sqlight.query(
      "SELECT id,COALESCE(NULLIF(title,''),'new session'),cwd,COALESCE(provider,''),model,protocol,stage,last_assistant_at FROM sessions ORDER BY activity_seq DESC,rowid DESC",
      db,
      [],
      info_decoder(),
    )
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn create(store: store.Store, info: Info) -> Result(Nil, String) {
  store.query(store, fn(db) {
    sqlight.query(
      "INSERT INTO sessions(id,title,cwd,provider,model,protocol,activity_seq,last_assistant_at) SELECT ?,?,?,?,?,?,COALESCE(MAX(activity_seq),0)+1,? FROM sessions",
      db,
      [
        sqlight.text(info.id),
        sqlight.text(info.title),
        sqlight.text(info.cwd),
        sqlight.text(info.provider),
        sqlight.text(info.model),
        sqlight.text(protocol(info.protocol)),
        sqlight.nullable(sqlight.int, info.last_assistant_at),
      ],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn protocol(protocol: types.Protocol) -> String {
  case protocol {
    types.Responses -> "responses"
    types.ChatCompletions -> "chat_completions"
  }
}

pub fn title(text: String) -> String {
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
  case clean {
    "" -> "new session"
    _ ->
      case string.length(clean) > 80 {
        True -> string.slice(clean, 0, 79) <> "…"
        False -> clean
      }
  }
}

fn has_visible_assistant(inputs: List(types.Input)) -> Bool {
  list.any(inputs, fn(input) {
    case events.visible_assistant_text(input) {
      Some(_) -> True
      None -> False
    }
  })
}

fn latest_user(inputs: List(types.Input)) -> Option(String) {
  list.fold(inputs, None, fn(latest, input) {
    case input {
      types.User(text) | types.UserImage(text, _) -> Some(text)
      _ -> latest
    }
  })
}

fn title_or_default(user: Option(String)) -> String {
  case user {
    Some(text) -> title(text)
    None -> "new session"
  }
}

pub fn load_entries(
  store: store.Store,
  id: String,
) -> Result(List(transcript.Entry), String) {
  store.query(store, fn(db) {
    use rows <- result.try(
      sqlight.query(
        "SELECT payload,timestamp,provider FROM transcript WHERE session=? ORDER BY seq",
        db,
        [sqlight.text(id)],
        {
          use payload <- decode.field(0, decode.bit_array)
          use timestamp <- decode.field(1, decode.optional(decode.int))
          use provider <- decode.field(2, decode.optional(decode.string))
          decode.success(#(payload, timestamp, provider))
        },
      )
      |> result.map_error(fn(e) { e.message }),
    )
    list.try_map(rows, fn(row) {
      use input <- result.try(
        unpack(row.0) |> result.replace_error("invalid saved transcript item"),
      )
      Ok(transcript.Entry(input, row.1, row.2))
    })
  })
}

pub fn load(
  store: store.Store,
  id: String,
) -> Result(List(types.Input), String) {
  load_entries(store, id)
  |> result.map(fn(entries) { list.map(entries, fn(entry) { entry.input }) })
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
  let timestamp = usage.now()
  store.query(store, fn(db) {
    use _ <- result.try(
      sqlight.exec("BEGIN IMMEDIATE", db)
      |> result.map_error(fn(e) { e.message }),
    )
    let written = {
      let advances_assistant = case has_visible_assistant(inputs) {
        True -> 1
        False -> 0
      }
      use _ <- result.try(
        list.try_each(inputs, fn(input) {
          sqlight.query(
            "INSERT INTO transcript(session,payload,timestamp,provider) VALUES(?,?,?,?)",
            db,
            [
              sqlight.text(id),
              sqlight.blob(pack(input)),
              sqlight.int(timestamp),
              sqlight.nullable(sqlight.text, provider),
            ],
            decode.dynamic,
          )
          |> result.replace(Nil)
          |> result.map_error(fn(e) { e.message })
        }),
      )
      case latest_user(inputs) {
        Some(text) ->
          sqlight.query(
            "UPDATE sessions SET stage=?,title=?,activity_seq=(SELECT COALESCE(MAX(activity_seq),0)+1 FROM sessions),last_assistant_at=CASE WHEN ?=1 THEN unixepoch() ELSE last_assistant_at END WHERE id=?",
            db,
            [
              sqlight.text(stage_name(stage)),
              sqlight.text(title(text)),
              sqlight.int(advances_assistant),
              sqlight.text(id),
            ],
            decode.dynamic,
          )
        None ->
          sqlight.query(
            "UPDATE sessions SET stage=?,activity_seq=(SELECT COALESCE(MAX(activity_seq),0)+1 FROM sessions),last_assistant_at=CASE WHEN ?=1 THEN unixepoch() ELSE last_assistant_at END WHERE id=?",
            db,
            [
              sqlight.text(stage_name(stage)),
              sqlight.int(advances_assistant),
              sqlight.text(id),
            ],
            decode.dynamic,
          )
      }
      |> result.replace(Nil)
      |> result.map_error(fn(e) { e.message })
    }
    case written {
      Ok(_) ->
        sqlight.exec("COMMIT", db)
        |> result.map(fn(_) { timestamp })
        |> result.map_error(fn(e) { e.message })
      Error(e) -> {
        let _ = sqlight.exec("ROLLBACK", db)
        Error(e)
      }
    }
  })
}

fn usage_decoder() {
  use model <- decode.field(0, decode.optional(decode.string))
  use recorded_at <- decode.field(1, decode.optional(decode.int))
  use prompt <- decode.field(2, decode.optional(decode.int))
  use completion <- decode.field(3, decode.optional(decode.int))
  use cached <- decode.field(4, decode.optional(decode.int))
  case model, recorded_at, prompt, completion {
    None, None, None, None -> decode.success(None)
    Some(model), Some(recorded_at), None, None ->
      decode.success(Some(usage.Metadata(model, recorded_at, None)))
    Some(model), Some(recorded_at), Some(prompt), Some(completion) ->
      decode.success(
        Some(usage.Metadata(
          model,
          recorded_at,
          Some(usage.Tokens(prompt, completion, cached)),
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
    sqlight.query(
      "SELECT usage_model,usage_recorded_at,usage_prompt_tokens,usage_completion_tokens,usage_cached_prompt_tokens FROM sessions WHERE id=?",
      db,
      [sqlight.text(id)],
      usage_decoder(),
    )
    |> result.map_error(fn(e) { e.message })
    |> result.try(fn(rows) {
      list.first(rows) |> result.replace_error("session not found")
    })
  })
}

pub fn clear_usage(store: store.Store, id: String) -> Result(Nil, String) {
  store.query(store, fn(db) {
    sqlight.query(
      "UPDATE sessions SET usage_model=NULL,usage_recorded_at=NULL,usage_prompt_tokens=NULL,usage_completion_tokens=NULL,usage_cached_prompt_tokens=NULL WHERE id=?",
      db,
      [sqlight.text(id)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}

pub fn record_usage(
  store: store.Store,
  id: String,
  metadata: usage.Metadata,
) -> Result(Nil, String) {
  let usage.Metadata(model, recorded_at, tokens) = metadata
  let #(prompt, completion, cached) = case tokens {
    Some(usage.Tokens(prompt, completion, cached)) -> #(
      Some(prompt),
      Some(completion),
      cached,
    )
    None -> #(None, None, None)
  }
  store.query(store, fn(db) {
    sqlight.query(
      "UPDATE sessions SET usage_model=?,usage_recorded_at=?,usage_prompt_tokens=?,usage_completion_tokens=?,usage_cached_prompt_tokens=? WHERE id=?",
      db,
      [
        sqlight.text(model),
        sqlight.int(recorded_at),
        sqlight.nullable(sqlight.int, prompt),
        sqlight.nullable(sqlight.int, completion),
        sqlight.nullable(sqlight.int, cached),
        sqlight.text(id),
      ],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

@external(erlang, "albedo_conversation", "pack")
fn pack(input: types.Input) -> BitArray

@external(erlang, "albedo_conversation", "unpack")
fn unpack(bytes: BitArray) -> Result(types.Input, Nil)

pub fn set_configuration(
  store: store.Store,
  id: String,
  provider: String,
  model: String,
  selected_protocol: types.Protocol,
) -> Result(Nil, String) {
  store.query(store, fn(db) {
    use _ <- result.try(
      sqlight.exec("BEGIN IMMEDIATE", db)
      |> result.map_error(fn(e) { e.message }),
    )
    let written = {
      use _ <- result.try(
        sqlight.query(
          "UPDATE transcript SET provider=(SELECT provider FROM sessions WHERE id=?) WHERE session=? AND provider IS NULL",
          db,
          [sqlight.text(id), sqlight.text(id)],
          decode.dynamic,
        )
        |> result.replace(Nil)
        |> result.map_error(fn(e) { e.message }),
      )
      sqlight.query(
        "UPDATE sessions SET provider=?,model=?,protocol=? WHERE id=?",
        db,
        [
          sqlight.text(provider),
          sqlight.text(model),
          sqlight.text(protocol(selected_protocol)),
          sqlight.text(id),
        ],
        decode.dynamic,
      )
      |> result.replace(Nil)
      |> result.map_error(fn(e) { e.message })
    }
    case written {
      Ok(_) ->
        sqlight.exec("COMMIT", db)
        |> result.replace(Nil)
        |> result.map_error(fn(e) { e.message })
      Error(error) -> {
        let _ = sqlight.exec("ROLLBACK", db)
        Error(error)
      }
    }
  })
}

/// Workspace changes are serialized by the session actor with submissions.
pub fn set_workspace(
  store: store.Store,
  id: String,
  cwd: String,
) -> Result(Nil, String) {
  store.query(store, fn(db) {
    sqlight.query(
      "UPDATE sessions SET cwd=? WHERE id=?",
      db,
      [sqlight.text(cwd), sqlight.text(id)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(error) { error.message })
  })
}
