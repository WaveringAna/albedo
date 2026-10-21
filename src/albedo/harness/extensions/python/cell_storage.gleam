//// The SQL the rest of the daemon runs on the python extension's `cells` and
//// `cell_traces` tables: storage accounting, session deletion and image
//// release. Nothing outside this extension names those tables.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

/// `SELECT session, bytes` over every cell, one row per session.
/// `traces` is whether the `cell_traces` table exists.
pub fn bytes_by_session_query(traces traces: Bool) -> String {
  "SELECT c.session," <> bytes(traces) <> " GROUP BY c.session"
}

/// An SQL expression for the bytes one session's cells hold, where `session`
/// is the SQL for that session's id.
pub fn bytes_of_session(
  traces traces: Bool,
  session session: String,
) -> String {
  "(SELECT " <> bytes(traces) <> " WHERE c.session=" <> session <> ")"
}

fn bytes(traces: Bool) -> String {
  let #(join, trace) = case traces {
    True -> #(
      "LEFT JOIN cell_traces t ON t.id=c.id",
      "COALESCE(LENGTH(t.payload),0)",
    )
    False -> #("", "0")
  }
  "COALESCE(SUM(LENGTH(c.source)+COALESCE(LENGTH(c.payload),0)+"
  <> trace
  <> "),0) FROM cells c "
  <> join
}

/// Removes a session's cells and their traces.
pub fn delete_session(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "DELETE FROM cell_traces WHERE id IN (SELECT id FROM cells WHERE session=?)",
      [sqlight.text(session)],
    ),
  )
  store.run(db, "DELETE FROM cells WHERE session=?", [sqlight.text(session)])
}

/// Every cell payload that names a stored image; none when the cells table
/// has not been created.
pub fn image_payloads(
  db: sqlight.Connection,
) -> Result(List(BitArray), String) {
  use tables <- result.try(store.rows(
    db,
    "SELECT name FROM sqlite_master WHERE type='table' AND name='cells'",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  case list.is_empty(tables) {
    True -> Ok([])
    False ->
      store.rows(
        db,
        "SELECT payload FROM cells WHERE payload IS NOT NULL AND instr(payload,CAST('stored_data' AS BLOB))>0",
        [],
        decode.field(0, decode.bit_array, decode.success),
      )
  }
}

/// The finished cells of one tool call: the cell with this id and its nested
/// ones (`<id>-...`), as (cell id, payload).
pub fn payloads_of_call(
  db: sqlight.Connection,
  id: String,
) -> Result(List(#(String, BitArray)), String) {
  store.rows(
    db,
    "SELECT id, payload FROM cells WHERE (id=? OR id LIKE ?) AND payload IS NOT NULL",
    [sqlight.text(id), sqlight.text(id <> "-%")],
    {
      use cell_id <- decode.field(0, decode.string)
      use payload <- decode.field(1, decode.bit_array)
      decode.success(#(cell_id, payload))
    },
  )
}

pub fn write_payload(
  db: sqlight.Connection,
  id: String,
  payload: BitArray,
) -> Result(Nil, String) {
  store.run(db, "UPDATE cells SET payload=? WHERE id=?", [
    sqlight.blob(payload),
    sqlight.text(id),
  ])
}
