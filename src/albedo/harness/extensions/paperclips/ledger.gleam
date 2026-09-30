//// The vent ledger: what the model found worth complaining about, kept for
//// the user to review. The model writes and lists; the user triages through
//// /paperclips. Rows live in the shared ledger store under one table.

import albedo/daemon/store as storage
import gleam/dynamic/decode
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
    status: Status,
    session: Option(String),
    created_at: String,
  )
}

pub type Error {
  Invalid(String)
  NotFound
  Storage(String)
}

pub type Store =
  storage.Store

/// Creates the table at install; the extension contributes its column upgrades.
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
 status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','acknowledged','resolved','dismissed')),
 session TEXT,
 cwd TEXT NOT NULL,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS paperclips_cwd ON paperclips(cwd);
"

const columns = "id,title,topic,message,suggestion,status,session,created_at"

pub fn topic_name(topic: Topic) -> String {
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

pub fn parse_status(name: String) -> Result(Status, Error) {
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

fn topic_decoder() {
  use value <- decode.then(decode.string)
  case parse_topic(value) {
    Ok(topic) -> decode.success(topic)
    Error(_) -> decode.failure(Other, "vent topic")
  }
}

fn status_decoder() {
  use value <- decode.then(decode.string)
  case parse_status(value) {
    Ok(status) -> decode.success(status)
    Error(_) -> decode.failure(Open, "vent status")
  }
}

fn decoder() {
  use id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use topic <- decode.field(2, topic_decoder())
  use message <- decode.field(3, decode.string)
  use suggestion <- decode.field(4, decode.string)
  use status <- decode.field(5, status_decoder())
  use session <- decode.field(6, decode.optional(decode.string))
  use created_at <- decode.field(7, decode.string)
  decode.success(Vent(
    id,
    title,
    topic,
    message,
    suggestion,
    status,
    session,
    created_at,
  ))
}

pub fn to_json(vent: Vent) -> json.Json {
  json.object([
    #("id", json.int(vent.id)),
    #("title", json.string(vent.title)),
    #("topic", json.string(topic_name(vent.topic))),
    #("message", json.string(vent.message)),
    #("suggestion", json.string(vent.suggestion)),
    #("status", json.string(status_name(vent.status))),
    #("session", json.nullable(vent.session, json.string)),
    #("created_at", json.string(vent.created_at)),
  ])
}

fn rows(db, sql, args) {
  storage.rows(db, sql, args, decoder()) |> result.map_error(Storage)
}

fn one(items: List(Vent)) -> Result(Vent, Error) {
  items |> list.first |> result.replace_error(NotFound)
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

/// Files one vent.
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

/// The most recent vents for one workspace, newest first, so review
/// starts at the top.
pub fn list(
  store: Store,
  cwd: String,
  limit: Int,
) -> Result(List(Vent), Error) {
  case limit < 1 || limit > 200 {
    True -> Error(Invalid("1 <= limit <= 200 required"))
    False ->
      storage.query(store, fn(db) {
        rows(
          db,
          "SELECT "
            <> columns
            <> " FROM paperclips WHERE cwd=? ORDER BY id DESC LIMIT ?",
          [sqlight.text(cwd), sqlight.int(limit)],
        )
      })
  }
}

pub fn get(store: Store, cwd: String, id: Int) -> Result(Vent, Error) {
  storage.query(store, find(_, cwd, id)) |> result.try(one)
}

fn find(db, cwd: String, id: Int) {
  rows(db, "SELECT " <> columns <> " FROM paperclips WHERE cwd=? AND id=?", [
    sqlight.text(cwd),
    sqlight.int(id),
  ])
}

/// Moves one vent's status; nothing else about a filed vent changes.
pub fn set_status(
  store: Store,
  cwd: String,
  id: Int,
  status: Status,
) -> Result(Vent, Error) {
  storage.query(store, fn(db) {
    use _ <- result.try(find(db, cwd, id) |> result.try(one))
    rows(
      db,
      "UPDATE paperclips SET status=?,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE cwd=? AND id=? RETURNING "
        <> columns,
      [sqlight.text(status_name(status)), sqlight.text(cwd), sqlight.int(id)],
    )
  })
  |> result.try(one)
}

pub fn delete(store: Store, cwd: String, id: Int) -> Result(Vent, Error) {
  storage.query(store, fn(db) {
    use _ <- result.try(find(db, cwd, id) |> result.try(one))
    rows(
      db,
      "DELETE FROM paperclips WHERE cwd=? AND id=? RETURNING " <> columns,
      [sqlight.text(cwd), sqlight.int(id)],
    )
  })
  |> result.try(one)
}
