import albedo/daemon/store as storage
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import sqlight

pub type Status {
  Open
  Active
  Blocked
  Done
  Cancelled
}

pub type Item {
  Item(
    id: Int,
    title: String,
    notes: String,
    status: Status,
    parent: Option(Int),
    session: Option(String),
    run: Option(String),
    revision: Int,
  )
}

pub type Error {
  Invalid(String)
  NotFound
  Conflict
  Storage(String)
}

pub type Store =
  storage.Store

pub fn start(path: String) -> Result(Store, actor.StartError) {
  storage.start(path, schema)
}

pub fn owner(store: Store) -> process.Pid {
  storage.owner(store)
}

pub fn close(store: Store) -> Nil {
  storage.close(store)
}

fn query(
  store: Store,
  run: fn(sqlight.Connection) -> Result(List(Item), Error),
) {
  storage.query(store, run)
}

const schema = "
PRAGMA journal_mode=WAL;
PRAGMA synchronous=FULL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=3000;
CREATE TABLE IF NOT EXISTS work (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 title TEXT NOT NULL CHECK(length(trim(title)) > 0),
 notes TEXT NOT NULL DEFAULT '',
 status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','active','blocked','done','cancelled')),
 parent INTEGER REFERENCES work(id),
 session TEXT,
 run TEXT CHECK(run IS NULL OR session IS NOT NULL),
 cwd TEXT NOT NULL DEFAULT '__albedo_legacy__',
 revision INTEGER NOT NULL DEFAULT 1,
 created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
);
CREATE INDEX IF NOT EXISTS work_parent ON work(parent);
CREATE INDEX IF NOT EXISTS work_session ON work(session);
"

const columns = "id,title,notes,status,parent,session,run,revision"

const legacy_cwd = "__albedo_legacy__"

fn valid_cwd(cwd: String) -> Result(Nil, Error) {
  case cwd == legacy_cwd || cwd == "" {
    True -> Error(Invalid("reserved or empty cwd"))
    False -> Ok(Nil)
  }
}

pub fn status_name(status: Status) -> String {
  case status {
    Open -> "open"
    Active -> "active"
    Blocked -> "blocked"
    Done -> "done"
    Cancelled -> "cancelled"
  }
}

pub fn parse_status(name: String) -> Result(Status, Error) {
  case name {
    "open" -> Ok(Open)
    "active" -> Ok(Active)
    "blocked" -> Ok(Blocked)
    "done" -> Ok(Done)
    "cancelled" -> Ok(Cancelled)
    _ ->
      Error(Invalid(
        "unknown work status "
        <> name
        <> "; use open, active, blocked, done, or cancelled",
      ))
  }
}

fn status_decoder() {
  use value <- decode.then(decode.string)
  case parse_status(value) {
    Ok(status) -> decode.success(status)
    Error(_) -> decode.failure(Open, "work status")
  }
}

fn decoder() {
  use id <- decode.field(0, decode.int)
  use title <- decode.field(1, decode.string)
  use notes <- decode.field(2, decode.string)
  use status <- decode.field(3, status_decoder())
  use parent <- decode.field(4, decode.optional(decode.int))
  use session <- decode.field(5, decode.optional(decode.string))
  use run <- decode.field(6, decode.optional(decode.string))
  use revision <- decode.field(7, decode.int)
  decode.success(Item(id, title, notes, status, parent, session, run, revision))
}

fn rows(db, sql, args) {
  sqlight.query(sql, db, args, decoder())
  |> result.map_error(fn(e) { Storage(e.message) })
}

fn one(items: List(Item)) -> Result(Item, Error) {
  items |> list.first |> result.replace_error(NotFound)
}

/// Keyset pagination. No unbounded ledger dumps into a model context.
pub fn list(
  store: Store,
  cwd: String,
  after: Int,
  limit: Int,
) -> Result(List(Item), Error) {
  use _ <- result.try(valid_cwd(cwd))
  case after < 0 || limit < 1 || limit > 200 {
    True -> Error(Invalid("after >= 0 and 1 <= limit <= 200 required"))
    False ->
      query(store, fn(db) {
        rows(
          db,
          "SELECT "
            <> columns
            <> " FROM work WHERE cwd=? AND id > ? ORDER BY id LIMIT ?",
          [sqlight.text(cwd), sqlight.int(after), sqlight.int(limit)],
        )
      })
  }
}

pub fn get(store: Store, cwd: String, id: Int) -> Result(Item, Error) {
  use _ <- result.try(valid_cwd(cwd))
  use items <- result.try(
    query(store, fn(db) {
      rows(db, "SELECT " <> columns <> " FROM work WHERE cwd=? AND id = ?", [
        sqlight.text(cwd),
        sqlight.int(id),
      ])
    }),
  )
  one(items)
}

pub fn create(
  store: Store,
  cwd: String,
  title: String,
  notes: String,
  parent: Option(Int),
) -> Result(Item, Error) {
  use _ <- result.try(valid_cwd(cwd))
  use _ <- result.try(validate(title, notes, None, None))
  use items <- result.try(
    query(store, fn(db) {
      use _ <- result.try(case parent {
        None -> Ok(Nil)
        Some(parent_id) ->
          case
            rows(db, "SELECT " <> columns <> " FROM work WHERE cwd=? AND id=?", [
              sqlight.text(cwd),
              sqlight.int(parent_id),
            ])
          {
            Error(error) -> Error(error)
            Ok([]) -> Error(NotFound)
            Ok(_) -> Ok(Nil)
          }
      })
      rows(
        db,
        "INSERT INTO work(cwd,title,notes,parent) VALUES(?,?,?,?) RETURNING "
          <> columns,
        [
          sqlight.text(cwd),
          sqlight.text(title),
          sqlight.text(notes),
          sqlight.nullable(sqlight.int, parent),
        ],
      )
    }),
  )
  one(items)
}

pub fn update(store: Store, cwd: String, item: Item) -> Result(Item, Error) {
  use _ <- result.try(valid_cwd(cwd))
  use _ <- result.try(validate(item.title, item.notes, item.session, item.run))
  use items <- result.try(
    query(store, fn(db) {
      use existing <- result.try(
        rows(db, "SELECT " <> columns <> " FROM work WHERE cwd=? AND id=?", [
          sqlight.text(cwd),
          sqlight.int(item.id),
        ]),
      )
      case existing {
        [] -> Error(NotFound)
        [current, ..] if current.parent != item.parent ->
          Error(Invalid("parent cannot change"))
        _ -> {
          use changed <- result.try(
            rows(
              db,
              "UPDATE work SET title=?,notes=?,status=?,session=?,run=?,revision=revision+1,updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE cwd=? AND id=? AND revision=? RETURNING "
                <> columns,
              [
                sqlight.text(item.title),
                sqlight.text(item.notes),
                sqlight.text(status_name(item.status)),
                sqlight.nullable(sqlight.text, item.session),
                sqlight.nullable(sqlight.text, item.run),
                sqlight.text(cwd),
                sqlight.int(item.id),
                sqlight.int(item.revision),
              ],
            ),
          )
          case changed {
            [] -> Error(Conflict)
            _ -> Ok(changed)
          }
        }
      }
    }),
  )
  one(items)
}

/// Remove one item at the revision the caller last saw. An item with children
/// stays: its sub-items would lose their parent.
pub fn delete(
  store: Store,
  cwd: String,
  id: Int,
  revision: Int,
) -> Result(Item, Error) {
  use _ <- result.try(valid_cwd(cwd))
  use items <- result.try(
    query(store, fn(db) {
      use existing <- result.try(
        rows(db, "SELECT " <> columns <> " FROM work WHERE cwd=? AND id=?", [
          sqlight.text(cwd),
          sqlight.int(id),
        ]),
      )
      use children <- result.try(
        rows(
          db,
          "SELECT " <> columns <> " FROM work WHERE cwd=? AND parent=? LIMIT 1",
          [
            sqlight.text(cwd),
            sqlight.int(id),
          ],
        ),
      )
      case existing, children {
        [], _ -> Error(NotFound)
        _, [_, ..] -> Error(Invalid("remove its sub-items first"))
        [current, ..], [] if current.revision != revision -> Error(Conflict)
        _, [] ->
          rows(
            db,
            "DELETE FROM work WHERE cwd=? AND id=? AND revision=? RETURNING "
              <> columns,
            [sqlight.text(cwd), sqlight.int(id), sqlight.int(revision)],
          )
      }
    }),
  )
  items |> list.first |> result.replace_error(Conflict)
}

fn validate(title, notes, session, run) {
  case
    string.trim(title) == ""
    || string.byte_size(title) > 4096
    || string.byte_size(notes) > 65_536
  {
    True ->
      Error(Invalid(
        "title must be nonempty and <= 4096 bytes; notes <= 65536 bytes",
      ))
    False ->
      case session, run {
        None, Some(_) -> Error(Invalid("a run requires a session"))
        _, _ -> Ok(Nil)
      }
  }
}

pub fn to_json(item: Item) -> json.Json {
  json.object([
    #("id", json.int(item.id)),
    #("title", json.string(item.title)),
    #("notes", json.string(item.notes)),
    #("status", json.string(status_name(item.status))),
    #("parent", json.nullable(item.parent, json.int)),
    #("session", json.nullable(item.session, json.string)),
    #("run", json.nullable(item.run, json.string)),
    #("revision", json.int(item.revision)),
  ])
}

pub fn initialise(store: Store) -> Result(Nil, String) {
  storage.query(store, fn(db) {
    use _ <- result.try(
      sqlight.exec(schema, db) |> result.map_error(fn(e) { e.message }),
    )
    use columns <- result.try(
      sqlight.query(
        "PRAGMA table_info(work)",
        db,
        [],
        decode.field(1, decode.string, decode.success),
      )
      |> result.map_error(fn(e) { e.message }),
    )
    use _ <- result.try(case list.contains(columns, "cwd") {
      True -> Ok(Nil)
      False ->
        sqlight.exec(
          "ALTER TABLE work ADD COLUMN cwd TEXT NOT NULL DEFAULT '__albedo_legacy__'",
          db,
        )
        |> result.map_error(fn(e) { e.message })
    })
    sqlight.exec("CREATE INDEX IF NOT EXISTS work_cwd_id ON work(cwd,id)", db)
    |> result.map_error(fn(e) { e.message })
  })
}
