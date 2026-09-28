import albedo/daemon/store
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Job {
  Job(
    id: Int,
    session: String,
    kind: String,
    prompt: String,
    next_at: Int,
    every: Option(Int),
  )
}

const schema = "
CREATE TABLE IF NOT EXISTS schedules (
 id INTEGER PRIMARY KEY AUTOINCREMENT,
 session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 kind TEXT NOT NULL CHECK(kind IN ('recurring','heartbeat','once')),
 prompt TEXT NOT NULL,
 next_at INTEGER NOT NULL,
 every_seconds INTEGER
);
CREATE INDEX IF NOT EXISTS schedules_due ON schedules(next_at);
"

pub fn initialise(db: store.Store) -> Result(Nil, String) {
  store.query(db, store.exec(_, schema))
}

@external(erlang, "albedo_schedule", "now")
pub fn now() -> Int

fn decoder() {
  use id <- decode.field(0, decode.int)
  use session <- decode.field(1, decode.string)
  use kind <- decode.field(2, decode.string)
  use prompt <- decode.field(3, decode.string)
  use next_at <- decode.field(4, decode.int)
  use every <- decode.field(5, decode.optional(decode.int))
  decode.success(Job(id, session, kind, prompt, next_at, every))
}

const columns = "id,session,kind,prompt,next_at,every_seconds"

pub fn list(db: store.Store, session: String) -> Result(List(Job), String) {
  store.read(
    db,
    "SELECT "
      <> columns
      <> " FROM schedules WHERE session=? ORDER BY next_at LIMIT 200",
    [sqlight.text(session)],
    decoder(),
  )
}

fn one(
  db: store.Store,
  sql: String,
  args: List(sqlight.Value),
) -> Result(Job, String) {
  store.query(db, store.one(_, sql, args, decoder(), "schedule not found"))
}

pub fn get(db: store.Store, session: String, id: Int) -> Result(Job, String) {
  one(db, "SELECT " <> columns <> " FROM schedules WHERE id=? AND session=?", [
    sqlight.int(id),
    sqlight.text(session),
  ])
}

pub fn due(db: store.Store, time: Int) -> Result(List(Job), String) {
  store.read(
    db,
    "SELECT "
      <> columns
      <> " FROM schedules WHERE next_at<=? ORDER BY next_at LIMIT 25",
    [sqlight.int(time)],
    decoder(),
  )
}

pub fn save(
  db: store.Store,
  session: String,
  id: Option(Int),
  kind: String,
  prompt: String,
  delay: Int,
  every: Option(Int),
) -> Result(Job, String) {
  case
    string.trim(prompt) == ""
    || string.byte_size(prompt) > 4096
    || delay < 1
    || delay > 31_536_000
  {
    True -> Error("prompt must be 1–4096 bytes and delay 1–31536000 seconds")
    False -> {
      let next = now() + delay
      let args = [
        sqlight.text(kind),
        sqlight.text(prompt),
        sqlight.int(next),
        sqlight.nullable(sqlight.int, every),
      ]
      let #(sql, values) = case id {
        None -> #(
          "INSERT INTO schedules(session,kind,prompt,next_at,every_seconds) VALUES(?,?,?,?,?) RETURNING "
            <> columns,
          [sqlight.text(session), ..args],
        )
        Some(id) -> #(
          "UPDATE schedules SET kind=?,prompt=?,next_at=?,every_seconds=? WHERE id=? AND session=? RETURNING "
            <> columns,
          list.append(args, [sqlight.int(id), sqlight.text(session)]),
        )
      }
      one(db, sql, values)
    }
  }
}

pub fn delete(
  db: store.Store,
  session: String,
  id: Int,
) -> Result(Bool, String) {
  store.read(
    db,
    "DELETE FROM schedules WHERE id=? AND session=? RETURNING 1",
    [sqlight.int(id), sqlight.text(session)],
    decode.dynamic,
  )
  |> result.map(fn(found) { !list.is_empty(found) })
}

/// Advance only the occurrence actually delivered. Downtime skips missed intervals.
pub fn advance(db: store.Store, job: Job, time: Int) -> Result(Nil, String) {
  let key = [sqlight.int(job.id), sqlight.int(job.next_at)]
  let #(sql, args) = case job.every {
    None -> #("DELETE FROM schedules WHERE id=? AND next_at=?", key)
    Some(seconds) -> {
      let elapsed = int.max(time - job.next_at, 0)
      let next = job.next_at + { elapsed / seconds + 1 } * seconds
      #("UPDATE schedules SET next_at=? WHERE id=? AND next_at=?", [
        sqlight.int(next),
        ..key
      ])
    }
  }
  store.write(db, sql, args)
}

pub fn to_json(job: Job) -> json.Json {
  json.object([
    #("id", json.int(job.id)),
    #("kind", json.string(job.kind)),
    #("prompt", json.string(job.prompt)),
    #("next_at", json.int(job.next_at)),
    #("every_seconds", json.nullable(job.every, json.int)),
  ])
}
