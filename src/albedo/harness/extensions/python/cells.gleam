//// Cell source and terminal results survive kernel loss. Never replay automatically.

import albedo/daemon/images
import albedo/daemon/store
import albedo/harness/extensions/python/kernel as python
import albedo/openai_api/types
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
    store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS cells (
      id TEXT PRIMARY KEY, session TEXT NOT NULL, source TEXT NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('saved','finished')),
      started INTEGER NOT NULL DEFAULT 0 CHECK(started IN (0,1)),
      parent TEXT REFERENCES cells(id),
      payload BLOB,
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      CHECK((status='saved' AND payload IS NULL) OR (status='finished' AND payload IS NOT NULL))
    ); CREATE INDEX IF NOT EXISTS cells_session ON cells(session); CREATE TABLE IF NOT EXISTS cell_traces(id TEXT PRIMARY KEY REFERENCES cells(id),payload BLOB NOT NULL);",
    )
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
  let primary = session <> "/" <> call_id
  let id = case exists(storage, primary) {
    True -> primary <> "-" <> new_id()
    False -> primary
  }
  begin_named(storage, id, session, code)
}

/// Whether a cell with this id already exists in storage.
fn exists(storage: store.Store, id: String) -> Bool {
  case
    store.read(
      storage,
      "SELECT 1 FROM cells WHERE id=?",
      [sqlight.text(id)],
      decode.field(0, decode.int, decode.success),
    )
  {
    Ok([_]) -> True
    _ -> False
  }
}

fn begin_named(
  storage: store.Store,
  id: String,
  session: String,
  code: String,
) -> Result(String, String) {
  use _ <- result.try(within_limit(code))
  store.write(
    storage,
    "INSERT INTO cells(id,session,source,status) VALUES(?,?,?,'saved')",
    [sqlight.text(id), sqlight.text(session), sqlight.text(code)],
  )
  |> result.map(fn(_) { id })
}

/// One update that must claim exactly one still-saved cell; `lost` names
/// what the claim found instead.
fn claim(
  storage: store.Store,
  update: String,
  values: List(sqlight.Value),
  lost: String,
) -> Result(Nil, String) {
  use rows <- result.try(store.read(storage, update, values, decode.dynamic))
  case rows {
    [_] -> Ok(Nil)
    _ -> Error(lost)
  }
}

pub fn finish(
  storage: store.Store,
  id: String,
  outcome: Result(python.Outcome, python.Error),
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use saved <- result.try(case outcome {
        Ok(finished) ->
          images.store_images(db, finished.images)
          |> result.map(fn(stored) {
            Ok(python.Outcome(..finished, images: stored))
          })
        Error(_) -> Ok(outcome)
      })
      use rows <- result.try(store.rows(
        db,
        "UPDATE cells SET status='finished',payload=? WHERE id=? AND status='saved' RETURNING id",
        [sqlight.blob(pack(saved)), sqlight.text(id)],
        decode.dynamic,
      ))
      case rows {
        [_] -> Ok(Nil)
        _ -> Error("cell already finished or missing")
      }
    })
  })
}

/// Record how an execution ended, unless it has not: a cell that outlived
/// its deadline while out of reach, or returns early as backgrounded, stays
/// started until the kernel records its final result.
pub fn settle(
  storage: store.Store,
  id: String,
  outcome: Result(python.Outcome, python.Error),
) -> Result(Nil, String) {
  case outcome {
    Error(python.Detached) -> Ok(Nil)
    Ok(python.Outcome(status: python.Backgrounded, ..)) -> Ok(Nil)
    _ -> finish(storage, id, outcome)
  }
}

/// Image references a session's cells hold; collect before deleting their rows.
pub fn session_hashes(
  db: sqlight.Connection,
  session: String,
) -> Result(List(String), String) {
  store.rows(
    db,
    "SELECT payload FROM cells WHERE session=? AND payload IS NOT NULL AND instr(payload,CAST('stored_data' AS BLOB))>0",
    [sqlight.text(session)],
    decode.field(0, decode.bit_array, decode.success),
  )
  |> result.map(fn(rows) { list.flat_map(rows, hashes) |> list.unique })
}

/// Finds the newest cell for a tool call: exact base id, or the newest
/// suffixed cell when a provider reuses tool call ids across turns.
pub fn find_call(
  storage: store.Store,
  base_id: String,
) -> Result(Cell, String) {
  use rows <- result.try(store.read(
    storage,
    "SELECT id FROM cells WHERE id=? OR id LIKE ? ORDER BY rowid DESC LIMIT 1",
    [sqlight.text(base_id), sqlight.text(base_id <> "-%")],
    decode.field(0, decode.string, decode.success),
  ))
  use id <- result.try(
    list.first(rows) |> result.replace_error("cell not found"),
  )
  get(storage, id)
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
  use rows <- result.try(store.read(
    storage,
    "SELECT session,source,payload,started,parent FROM cells WHERE id=?",
    [sqlight.text(id)],
    decoder,
  ))
  use #(session, source, payload, started, parent) <- result.try(
    list.first(rows) |> result.replace_error("cell not found"),
  )
  case payload {
    None -> Ok(Cell(id, session, source, started, parent, None))
    Some(payload) ->
      unpack(payload, images.reader(storage))
      |> result.replace_error("invalid or unsupported cell payload")
      |> result.map(fn(outcome) {
        Cell(id, session, source, started, parent, Some(outcome))
      })
  }
}

/// This session's started cells that never recorded an end: still running,
/// or ended with their kernel. Newest first, as `(id, source)`.
pub fn unfinished(
  storage: store.Store,
  session: String,
) -> Result(List(#(String, String)), String) {
  let decoder = {
    use id <- decode.field(0, decode.string)
    use source <- decode.field(1, decode.string)
    decode.success(#(id, source))
  }
  store.read(
    storage,
    "SELECT id,source FROM cells WHERE session=? AND status='saved' AND started=1 ORDER BY rowid DESC",
    [sqlight.text(session)],
    decoder,
  )
}

/// This session's cells, newest first, at most `limit` of them.
pub fn recent(
  storage: store.Store,
  session: String,
  limit: Int,
) -> Result(List(Cell), String) {
  use ids <- result.try(store.read(
    storage,
    "SELECT id FROM cells WHERE session=? ORDER BY rowid DESC LIMIT ?",
    [sqlight.text(session), sqlight.int(limit)],
    decode.field(0, decode.string, decode.success),
  ))
  list.try_map(ids, get(storage, _))
}

/// The first nonempty source line, cut to 120 graphemes: a cell's display.
pub fn first_line(source: String) -> String {
  source
  |> string.split("\n")
  |> list.find(fn(line) { string.trim(line) != "" })
  |> result.unwrap("")
  |> string.slice(0, 120)
}

@external(erlang, "albedo_native", "new_id")
fn new_id() -> String

@external(erlang, "albedo_native", "pack_cell")
fn pack(outcome: Result(python.Outcome, python.Error)) -> BitArray

@external(erlang, "albedo_native", "cell_hashes")
fn hashes(payload: BitArray) -> List(String)

@external(erlang, "albedo_native", "unpack_cell")
fn unpack(
  payload: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(Result(python.Outcome, python.Error), Nil)

pub fn mark_started(storage: store.Store, id: String) -> Result(Nil, String) {
  claim(
    storage,
    "UPDATE cells SET started=1 WHERE id=? AND status='saved' AND started=0 RETURNING id",
    [sqlight.text(id)],
    "cell already started or unavailable",
  )
}

/// Cell source never exceeds 1 MiB, saved or rewritten.
fn within_limit(source: String) -> Result(Nil, String) {
  case string.byte_size(source) <= 1_048_576 {
    True -> Ok(Nil)
    False -> Error("cell source exceeds 1 MiB")
  }
}

fn rewritten(
  original: Cell,
  replacements: List(#(String, String)),
) -> Result(String, String) {
  list.try_fold(replacements, original.source, fn(source, replacement) {
    let #(old, new) = replacement
    use _ <- result.try(case old {
      "" -> Error("replacement requires nonempty old text")
      _ -> Ok(Nil)
    })
    use changed <- result.try(case string.split(source, old) {
      [before, after] -> Ok(before <> new <> after)
      [_] -> Error(missed(source, old))
      _ ->
        Error("replacement must match exactly once; inspect cells.read first")
    })
    use _ <- result.try(within_limit(changed))
    Ok(changed)
  })
}

/// The error for old text the cell does not contain, naming a difference in
/// whitespace alone when that is all that separates them.
fn missed(source: String, old: String) -> String {
  let base = "replacement must match exactly once; inspect cells.read first"
  case string.contains(squash(source), squash(old)) {
    True ->
      base
      <> ". The text is there, but whitespace differs (indentation, tabs,"
      <> " trailing spaces or line endings)"
    False -> base
  }
}

fn squash(text: String) -> String {
  text
  |> string.replace("\r", " ")
  |> string.replace("\t", " ")
  |> string.replace("\n", " ")
  |> string.split(" ")
  |> list.filter(fn(word) { word != "" })
  |> string.join(" ")
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
    store.write(
      storage,
      "INSERT INTO cells(id,session,source,status,parent) VALUES(?,?,?,'saved',?)",
      [
        sqlight.text(new_id),
        sqlight.text(original.session),
        sqlight.text(source),
        sqlight.text(id),
      ],
    ),
  )
  Ok(Cell(new_id, original.session, source, False, Some(id), None))
}

pub fn save_trace(
  storage: store.Store,
  id: String,
  value: Dynamic,
) -> Result(Nil, String) {
  store.write(
    storage,
    "INSERT OR REPLACE INTO cell_traces(id,payload) VALUES(?,?)",
    [sqlight.text(id), sqlight.blob(pack_trace(value))],
  )
}

pub fn trace(storage: store.Store, id: String) -> Option(Json) {
  store.read(
    storage,
    "SELECT payload FROM cell_traces WHERE id=?",
    [sqlight.text(id)],
    decode.field(0, decode.bit_array, decode.success),
  )
  |> result.replace_error(Nil)
  |> result.try(list.first)
  |> result.try(unpack_trace)
  |> result.map(types.encode_value)
  |> option.from_result
}

/// History captures retrieve the selected cells on their existing connection.
/// A missing extension table is absence; a failed read or corrupt trace is an
/// error, so the caller cannot install an incomplete successful snapshot.
pub fn traces_in(
  db: sqlight.Connection,
  ids: List(String),
) -> Result(List(#(String, Json)), String) {
  case ids {
    [] -> Ok([])
    _ -> {
      use tables <- result.try(store.rows(
        db,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='cell_traces'",
        [],
        decode.field(0, decode.string, decode.success),
      ))
      case tables {
        [] -> Ok([])
        _ -> {
          let placeholders = list.map(ids, fn(_) { "?" }) |> string.join(",")
          use rows <- result.try(
            store.rows(
              db,
              "SELECT id,payload FROM cell_traces WHERE id IN ("
                <> placeholders
                <> ")",
              list.map(ids, sqlight.text),
              {
                use id <- decode.field(0, decode.string)
                use payload <- decode.field(1, decode.bit_array)
                decode.success(#(id, payload))
              },
            ),
          )
          list.try_map(rows, fn(row) {
            unpack_trace(row.1)
            |> result.map(fn(value) { #(row.0, types.encode_value(value)) })
            |> result.replace_error("invalid saved cell trace")
          })
        }
      }
    }
  }
}

@external(erlang, "albedo_conversation", "pack")
fn pack_trace(value: Dynamic) -> BitArray

@external(erlang, "albedo_conversation", "unpack_trace")
fn unpack_trace(bytes: BitArray) -> Result(Dynamic, Nil)
