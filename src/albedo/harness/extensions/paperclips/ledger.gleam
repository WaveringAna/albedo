//// The vent ledger: what the model found worth complaining about, kept for
//// the user to review. The model writes and lists; the user triages through
//// /paperclips. Rows live in the shared ledger store under one global table:
//// every session sees every vent, and each row records the session and
//// workspace that filed it, plus the reply the user answered it with and,
//// when a model closed it, the note on what fixed it and the session that did.

import albedo/daemon/store as storage
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import sqlight

pub type Topic {
  Harness
  Workflow
  Bug
  User
  Other
}

pub type Status {
  Open
  Acknowledged
  Resolved
  Dismissed
}

pub type Vent {
  Vent(
    id: Int,
    title: String,
    topic: Topic,
    message: String,
    suggestion: String,
    reply: String,
    status: Status,
    session: Option(String),
    cwd: String,
    created_at: String,
    resolution: String,
    resolved_by: Option(String),
  )
}

pub type Error {
  Invalid(String)
  NotFound
  Storage(String)
}

pub type Store =
  storage.Store

/// Creates the table at install; the extension contributes its upgrades.
pub fn initialise(ledger: Store) -> Result(Nil, String) {
  storage.query(ledger, storage.exec(_, schema))
}

const schema = "
CREATE TABLE IF NOT EXISTS paperclips (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 topic TEXT NOT NULL CHECK(topic IN ('harness','workflow','bug','user','other')),
 title TEXT NOT NULL DEFAULT '',
 message TEXT NOT NULL CHECK(length(trim(message)) > 0),
 suggestion TEXT NOT NULL DEFAULT '',
 reply TEXT NOT NULL DEFAULT '',
 resolution TEXT NOT NULL DEFAULT '',
 resolved_by TEXT,
 status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','acknowledged','resolved','dismissed')),
 session TEXT,
 cwd TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
"

const columns = "id,title,topic,message,suggestion,reply,status,session,cwd,created_at,resolution,resolved_by"

fn topic_name(topic: Topic) -> String {
  case topic {
    Harness -> "harness"
    Workflow -> "workflow"
    Bug -> "bug"
    User -> "user"
    Other -> "other"
  }
}

pub fn parse_topic(name: String) -> Result(Topic, Error) {
  case name {
    "harness" -> Ok(Harness)
    "workflow" -> Ok(Workflow)
    "bug" -> Ok(Bug)
    "user" -> Ok(User)
    "other" -> Ok(Other)
    _ ->
      Error(Invalid(
        "unknown vent topic "
        <> name
        <> "; use harness, workflow, bug, user, or other",
      ))
  }
}

pub fn status_name(status: Status) -> String {
  case status {
    Open -> "open"
    Acknowledged -> "acknowledged"
    Resolved -> "resolved"
    Dismissed -> "dismissed"
  }
}

fn parse_status(name: String) -> Result(Status, Error) {
  case name {
    "open" -> Ok(Open)
    "acknowledged" -> Ok(Acknowledged)
    "resolved" -> Ok(Resolved)
    "dismissed" -> Ok(Dismissed)
    _ ->
      Error(Invalid(
        "unknown vent status "
        <> name
        <> "; use open, acknowledged, resolved, or dismissed",
      ))
  }
}

fn topic_decoder() -> decode.Decoder(Topic) {
  use value <- decode.then(decode.string)
  case parse_topic(value) {
    Ok(topic) -> decode.success(topic)
    Error(_) -> decode.failure(Other, "vent topic")
  }
}

fn status_decoder() -> decode.Decoder(Status) {
  use value <- decode.then(decode.string)
  case parse_status(value) {
    Ok(status) -> decode.success(status)
    Error(_) -> decode.failure(Open, "vent status")
  }
}

fn decoder() -> decode.Decoder(Vent) {
  use id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use topic <- decode.field(2, topic_decoder())
  use message <- decode.field(3, decode.string)
  use suggestion <- decode.field(4, decode.string)
  use reply <- decode.field(5, decode.string)
  use status <- decode.field(6, status_decoder())
  use session <- decode.field(7, decode.optional(decode.string))
  use cwd <- decode.field(8, decode.string)
  use created_at <- decode.field(9, decode.string)
  use resolution <- decode.field(10, decode.string)
  use resolved_by <- decode.field(11, decode.optional(decode.string))
  decode.success(Vent(
    id,
    title,
    topic,
    message,
    suggestion,
    reply,
    status,
    session,
    cwd,
    created_at,
    resolution,
    resolved_by,
  ))
}

pub fn to_json(vent: Vent) -> json.Json {
  json.object([
    #("id", json.int(vent.id)),
    #("title", json.string(vent.title)),
    #("topic", json.string(topic_name(vent.topic))),
    #("message", json.string(vent.message)),
    #("suggestion", json.string(vent.suggestion)),
    #("reply", json.string(vent.reply)),
    #("status", json.string(status_name(vent.status))),
    #("session", json.nullable(vent.session, json.string)),
    #("cwd", json.string(vent.cwd)),
    #("created_at", json.string(vent.created_at)),
    #("resolution", json.string(vent.resolution)),
    #("resolved_by", json.nullable(vent.resolved_by, json.string)),
  ])
}

fn rows(
  db: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
) -> Result(List(Vent), Error) {
  storage.rows(db, sql, args, decoder()) |> result.map_error(Storage)
}

fn one(items: List(Vent)) -> Result(Vent, Error) {
  items |> list.first |> result.replace_error(NotFound)
}

fn within(limit: Int) -> Result(Nil, Error) {
  case limit < 1 || limit > 200 {
    True -> Error(Invalid("1 <= limit <= 200 required"))
    False -> Ok(Nil)
  }
}

fn validate(
  title: String,
  message: String,
  suggestion: String,
) -> Result(Nil, Error) {
  case string.trim(message) == "" {
    True -> Error(Invalid("a vent needs a message"))
    False ->
      case
        string.length(title) > 200
        || string.length(suggestion) > 2000
        || string.length(message) > 8000
      {
        True -> Error(Invalid("vent text is too long"))
        False -> Ok(Nil)
      }
  }
}

/// Files one vent. `cwd` and `session` record where it came from; the
/// ledger itself is global.
pub fn create(
  store: Store,
  cwd: String,
  topic: Topic,
  title: String,
  message: String,
  suggestion: String,
  session: Option(String),
) -> Result(Vent, Error) {
  use _ <- result.try(validate(title, message, suggestion))
  storage.query(store, fn(db) {
    rows(
      db,
      "INSERT INTO paperclips(cwd,title,topic,message,suggestion,session) VALUES(?,?,?,?,?,?) RETURNING "
        <> columns,
      [
        sqlight.text(cwd),
        sqlight.text(string.trim(title)),
        sqlight.text(topic_name(topic)),
        sqlight.text(message),
        sqlight.text(suggestion),
        sqlight.nullable(sqlight.text, session),
      ],
    )
  })
  |> result.try(one)
}

/// The most recent vents anywhere, newest first, so review starts at the top.
pub fn list(store: Store, limit: Int) -> Result(List(Vent), Error) {
  use _ <- result.try(within(limit))
  storage.query(store, fn(db) {
    rows(
      db,
      "SELECT " <> columns <> " FROM paperclips ORDER BY id DESC LIMIT ?",
      [sqlight.int(limit)],
    )
  })
}

/// The review listing: open vents first, then acknowledged, then the quietly
/// finished ones, newest within each rank — so an old open vent is never
/// crowded out of triage by newer closed ones.
pub fn review(store: Store, limit: Int) -> Result(List(Vent), Error) {
  use _ <- result.try(within(limit))
  storage.query(store, fn(db) {
    rows(
      db,
      "SELECT "
        <> columns
        <> " FROM paperclips ORDER BY CASE status WHEN 'open' THEN 0 WHEN 'acknowledged' THEN 1 WHEN 'resolved' THEN 2 ELSE 3 END, id DESC LIMIT ?",
      [sqlight.int(limit)],
    )
  })
}

/// The display name for each of `ids`, one query for a whole listing: the
/// name someone gave the session, else a child's family name, else its
/// title — the same precedence the agents view uses. An unnamed session, or
/// one whose row is already gone, is left out; the caller falls back to the
/// id.
pub fn session_labels(
  store: Store,
  ids: List(String),
) -> Result(Dict(String, String), Error) {
  case ids {
    [] -> Ok(dict.new())
    _ -> {
      let placeholders = ids |> list.map(fn(_) { "?" }) |> string.join(",")
      storage.query(store, fn(db) {
        storage.rows(
          db,
          "SELECT s.id, COALESCE(NULLIF(s.name,''), f.name, NULLIF(s.title,'new session'), '')"
            <> " FROM sessions s LEFT JOIN session_family f ON f.session=s.id"
            <> " WHERE s.id IN ("
            <> placeholders
            <> ")",
          list.map(ids, sqlight.text),
          label_decoder(),
        )
      })
      |> result.map_error(Storage)
      |> result.map(fn(pairs) {
        pairs |> list.filter(fn(pair) { pair.1 != "" }) |> dict.from_list
      })
    }
  }
}

fn label_decoder() -> decode.Decoder(#(String, String)) {
  use id <- decode.field(0, decode.string)
  use label <- decode.field(1, decode.string)
  decode.success(#(id, label))
}

pub fn get(store: Store, id: Int) -> Result(Vent, Error) {
  storage.query(store, fn(db) {
    rows(db, "SELECT " <> columns <> " FROM paperclips WHERE id=?", [
      sqlight.int(id),
    ])
  })
  |> result.try(one)
}

/// Moves one vent's status; nothing else about a filed vent changes.
pub fn set_status(
  store: Store,
  id: Int,
  status: Status,
) -> Result(Vent, Error) {
  storage.query(store, fn(db) {
    rows(
      db,
      "UPDATE paperclips SET status=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? RETURNING "
        <> columns,
      [sqlight.text(status_name(status)), sqlight.int(id)],
    )
  })
  |> result.try(one)
}

/// Records the user's answer on the vent and acknowledges it: the reply is
/// durable even when the session that filed the vent can no longer be told.
pub fn answer(store: Store, id: Int, reply: String) -> Result(Vent, Error) {
  case string.length(reply) > 8000 {
    True -> Error(Invalid("vent text is too long"))
    False ->
      storage.query(store, fn(db) {
        rows(
          db,
          "UPDATE paperclips SET status='acknowledged',reply=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? RETURNING "
            <> columns,
          [sqlight.text(reply), sqlight.int(id)],
        )
      })
      |> result.try(one)
  }
}

/// Closes a vent a model fixed, recording what fixed it and which session
/// said so. Only a vent still awaiting triage can be resolved this way; the
/// user's own decisions stand.
pub fn resolve(
  store: Store,
  id: Int,
  note: String,
  session: String,
) -> Result(Vent, Error) {
  use _ <- result.try(case string.trim(note), string.length(note) > 2000 {
    "", _ -> Error(Invalid("say what fixed the vent: resolve_vent(id, note)"))
    _, True -> Error(Invalid("vent text is too long"))
    _, False -> Ok(Nil)
  })
  use vent <- result.try(get(store, id))
  use _ <- result.try(case vent.status {
    Open | Acknowledged -> Ok(Nil)
    status ->
      Error(Invalid(
        "vent #" <> int.to_string(id) <> " is already " <> status_name(status),
      ))
  })
  storage.query(store, fn(db) {
    rows(
      db,
      "UPDATE paperclips SET status='resolved',resolution=?,resolved_by=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE id=? AND status IN ('open','acknowledged') RETURNING "
        <> columns,
      [sqlight.text(string.trim(note)), sqlight.text(session), sqlight.int(id)],
    )
  })
  |> result.try(one)
}

pub fn delete(store: Store, id: Int) -> Result(Vent, Error) {
  storage.query(store, fn(db) {
    rows(db, "DELETE FROM paperclips WHERE id=? RETURNING " <> columns, [
      sqlight.int(id),
    ])
  })
  |> result.try(one)
}
