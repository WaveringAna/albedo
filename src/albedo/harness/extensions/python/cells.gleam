//// Cell source and terminal results survive kernel loss. Never replay automatically.

import albedo/daemon/store
import albedo/harness/extensions/python/kernel as python
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Cell {
  Cell(
    id: String,
    session: String,
    source: String,
    started: Bool,
    parent: Option(String),
    outcome: Option(Result(python.Outcome, python.Error)),
  )
}

/// started is committed before evaluation. An unfinished started cell has unknown effects.
pub fn initialise(storage: store.Store) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    sqlight.exec(
      "CREATE TABLE IF NOT EXISTS cells (
      id TEXT PRIMARY KEY, session TEXT NOT NULL, source TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('saved','finished')),
      started INTEGER NOT NULL DEFAULT 0 CHECK(started IN (0,1)),
      parent TEXT REFERENCES cells(id),
      payload BLOB,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      CHECK((status='saved' AND payload IS NULL) OR (status='finished' AND payload IS NOT NULL))
    ); CREATE INDEX IF NOT EXISTS cells_session ON cells(session); CREATE TABLE IF NOT EXISTS cell_traces(id TEXT PRIMARY KEY REFERENCES cells(id),payload BLOB NOT NULL);",
      db,
    )
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn begin(
  storage: store.Store,
  session: String,
  code: String,
) -> Result(String, String) {
  begin_named(storage, new_id(), session, code)
}

pub fn begin_call(
  storage: store.Store,
  session: String,
  call_id: String,
  code: String,
) -> Result(String, String) {
  begin_named(storage, session <> "/" <> call_id, session, code)
}

fn begin_named(
  storage: store.Store,
  id: String,
  session: String,
  code: String,
) -> Result(String, String) {
  use _ <- result.try(case string.byte_size(code) <= 1_048_576 {
    True -> Ok(Nil)
    False -> Error("cell source exceeds 1 MiB")
  })
  store.query(storage, fn(db) {
    sqlight.query(
      "INSERT INTO cells(id,session,source,status) VALUES(?,?,?,'saved')",
      db,
      [sqlight.text(id), sqlight.text(session), sqlight.text(code)],
      decode.dynamic,
    )
    |> result.map(fn(_) { id })
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn finish(
  storage: store.Store,
  id: String,
  outcome: Result(python.Outcome, python.Error),
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    use rows <- result.try(
      sqlight.query(
        "UPDATE cells SET status='finished',payload=? WHERE id=? AND status='saved' RETURNING id",
        db,
        [sqlight.blob(pack(outcome)), sqlight.text(id)],
        decode.dynamic,
      )
      |> result.map_error(fn(e) { e.message }),
    )
    case rows {
      [_] -> Ok(Nil)
      _ -> Error("cell already finished or missing")
    }
  })
}

pub fn get(storage: store.Store, id: String) -> Result(Cell, String) {
  let decoder = {
    use session <- decode.field(0, decode.string)
    use source <- decode.field(1, decode.string)
    use payload <- decode.field(2, decode.optional(decode.bit_array))
    use started <- decode.field(3, sqlight.decode_bool())
    use parent <- decode.field(4, decode.optional(decode.string))
    decode.success(#(session, source, payload, started, parent))
  }
  use rows <- result.try(
    store.query(storage, fn(db) {
      sqlight.query(
        "SELECT session,source,payload,started,parent FROM cells WHERE id=?",
        db,
        [sqlight.text(id)],
        decoder,
      )
      |> result.map_error(fn(e) { e.message })
    }),
  )
  case rows {
    [#(session, source, None, started, parent)] ->
      Ok(Cell(id, session, source, started, parent, None))
    [#(session, source, Some(payload), started, parent)] -> {
      use outcome <- result.try(
        unpack(payload)
        |> result.replace_error("invalid or unsupported cell payload"),
      )
      Ok(Cell(id, session, source, started, parent, Some(outcome)))
    }
    _ -> Error("cell not found")
  }
}

/// This session's cells, newest first, at most `limit` of them.
pub fn recent(
  storage: store.Store,
  session: String,
  limit: Int,
) -> Result(List(Cell), String) {
  use ids <- result.try(
    store.query(storage, fn(db) {
      sqlight.query(
        "SELECT id FROM cells WHERE session=? ORDER BY rowid DESC LIMIT ?",
        db,
        [sqlight.text(session), sqlight.int(limit)],
        decode.field(0, decode.string, decode.success),
      )
      |> result.map_error(fn(e) { e.message })
    }),
  )
  list.try_map(ids, get(storage, _))
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

@external(erlang, "albedo_native", "pack_cell")
fn pack(outcome: Result(python.Outcome, python.Error)) -> BitArray

@external(erlang, "albedo_native", "unpack_cell")
fn unpack(
  payload: BitArray,
) -> Result(Result(python.Outcome, python.Error), Nil)

pub fn mark_started(storage: store.Store, id: String) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    use rows <- result.try(
      sqlight.query(
        "UPDATE cells SET started=1 WHERE id=? AND status='saved' AND started=0 RETURNING id",
        db,
        [sqlight.text(id)],
        decode.dynamic,
      )
      |> result.map_error(fn(e) { e.message }),
    )
    case rows {
      [_] -> Ok(Nil)
      _ -> Error("cell already started or unavailable")
    }
  })
}

fn rewritten(
  original: Cell,
  replacements: List(#(String, String)),
) -> Result(String, String) {
  list.try_fold(replacements, original.source, fn(source, replacement) {
    let #(old, new) = replacement
    case old {
      "" -> Error("replacement requires nonempty old text")
      _ ->
        case string.split(source, old) {
          [before, after] -> {
            let changed = before <> new <> after
            case string.byte_size(changed) <= 1_048_576 {
              True -> Ok(changed)
              False -> Error("cell source exceeds 1 MiB")
            }
          }
          _ ->
            Error(
              "replacement must match exactly once; inspect cells.read first",
            )
        }
    }
  })
}

/// The rewritten source of a dry run: nothing is saved and nothing may execute.
pub fn draft(
  storage: store.Store,
  id: String,
  replacements: List(#(String, String)),
) -> Result(String, String) {
  use original <- result.try(get(storage, id))
  rewritten(original, replacements)
}

/// Exact sequential replacements produce a new immutable cell, never change the original.
pub fn prepare(
  storage: store.Store,
  id: String,
  replacements: List(#(String, String)),
  allow_partial: Bool,
) -> Result(Cell, String) {
  use original <- result.try(get(storage, id))
  use _ <- result.try(case original.started && !allow_partial {
    True ->
      Error(
        "cell execution started; inspect side effects, then use allow_partial=True to explicitly permit replay",
      )
    False -> Ok(Nil)
  })
  use source <- result.try(rewritten(original, replacements))
  let new_id = new_id()
  use _ <- result.try(
    store.query(storage, fn(db) {
      sqlight.query(
        "INSERT INTO cells(id,session,source,status,parent) VALUES(?,?,?,'saved',?)",
        db,
        [
          sqlight.text(new_id),
          sqlight.text(original.session),
          sqlight.text(source),
          sqlight.text(id),
        ],
        decode.dynamic,
      )
      |> result.map_error(fn(e) { e.message })
    }),
  )
  Ok(Cell(new_id, original.session, source, False, Some(id), None))
}

pub fn save_trace(
  storage: store.Store,
  id: String,
  value: Dynamic,
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    sqlight.query(
      "INSERT OR REPLACE INTO cell_traces(id,payload) VALUES(?,?)",
      db,
      [sqlight.text(id), sqlight.blob(pack_trace(value))],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

pub fn trace(storage: store.Store, id: String) -> Option(Json) {
  store.query(storage, fn(db) {
    sqlight.query(
      "SELECT payload FROM cell_traces WHERE id=?",
      db,
      [sqlight.text(id)],
      decode.field(0, decode.bit_array, decode.success),
    )
  })
  |> result.replace_error(Nil)
  |> result.try(list.first)
  |> result.try(unpack_trace)
  |> result.map(encode_trace)
  |> fn(value) {
    case value {
      Ok(value) -> Some(value)
      Error(_) -> None
    }
  }
}

@external(erlang, "albedo_conversation", "pack")
fn pack_trace(value: Dynamic) -> BitArray

@external(erlang, "albedo_conversation", "unpack_trace")
fn unpack_trace(bytes: BitArray) -> Result(Dynamic, Nil)

@external(erlang, "albedo_openai_json", "encode")
fn encode_trace(value: Dynamic) -> Json
