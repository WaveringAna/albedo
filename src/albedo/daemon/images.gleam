//// Image payloads stored once by content hash, out of transcript rows.
////
//// A transcript row keeps an image's hash and metadata; its decoded bytes live
//// in `images`. Loading a session therefore reads references, and a payload is
//// read only while a request body is written (albedo_openai_transport.erl).
//// Rows are content-addressed, so forks and repeated screenshots share one copy.

import albedo/daemon/image_payloads
import albedo/daemon/store
import albedo/openai_api/types
import gleam/bool
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

pub const schema =
  "CREATE TABLE IF NOT EXISTS images(hash TEXT PRIMARY KEY,data BLOB NOT NULL); CREATE TABLE IF NOT EXISTS migrations(name TEXT PRIMARY KEY,applied_at INTEGER NOT NULL);"

/// Fetches a stored payload. Never call the result from inside `store.query`:
/// the read is itself a store query, and the store runs one at a time.
pub fn reader(ledger: store.Store) -> fn(String) -> Result(String, Nil) {
  fn(hash) { store.query(ledger, fn(db) { read(db, hash) }) }
}

fn read(db: sqlight.Connection, hash: String) -> Result(String, Nil) {
  // Older databases can hold TEXT rows until their startup migration completes.
  case
    store.rows(
      db,
      "SELECT data FROM images WHERE hash=? AND typeof(data)='text'",
      [sqlight.text(hash)],
      decode.field(0, decode.string, decode.success),
    )
  {
    Ok([data]) -> Ok(data)
    Ok([]) ->
      case
        store.rows(
          db,
          "SELECT data FROM images WHERE hash=? AND typeof(data)='blob'",
          [sqlight.text(hash)],
          decode.field(0, decode.bit_array, decode.success),
        )
      {
        Ok([data]) -> Ok(encode_base64(data))
        _ -> Error(Nil)
      }
    _ -> Error(Nil)
  }
}

/// An image's decoded bytes, for serving the image itself. Same caveat as
/// `reader`: never call this from inside `store.query`.
pub fn bytes(ledger: store.Store, image: types.Image) -> Result(BitArray, Nil) {
  case types.image_data(image) {
    types.InlineData(data) -> decode_legacy_base64(data)
    types.StoredData(hash: hash, ..) -> stored_bytes(ledger, hash)
  }
}

fn stored_bytes(ledger: store.Store, hash: String) -> Result(BitArray, Nil) {
  store.query(ledger, fn(db) {
    case
      store.rows(
        db,
        "SELECT data FROM images WHERE hash=? AND typeof(data)='blob'",
        [sqlight.text(hash)],
        decode.field(0, decode.bit_array, decode.success),
      )
    {
      Ok([data]) -> Ok(data)
      _ -> read(db, hash) |> result.try(decode_legacy_base64)
    }
  })
}

/// The input with its inline images replaced by stored references, after
/// writing their payloads. Runs inside the caller's transaction.
pub fn externalize(
  db: sqlight.Connection,
  input: types.Input,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, String) {
  let #(stored, blobs) = split(input, read)
  use _ <- result.try(image_payloads.insert(db, blobs))
  Ok(stored)
}

/// Stores inline images, such as a cell's, in the caller's transaction. The
/// returned references acquire their live reader when their row is loaded.
pub fn store_images(
  db: sqlight.Connection,
  images: List(types.Image),
) -> Result(List(types.Image), String) {
  let #(stored, blobs) =
    split(types.ToolOutput("", "", images), fn(_) { Error(Nil) })
  use _ <- result.try(image_payloads.insert(db, blobs))
  let assert types.ToolOutput(_, _, images) = stored
  Ok(images)
}

/// Hashes the given session's rows reference, read before those rows are
/// deleted so `release` can drop payloads nothing else needs.
pub fn session_hashes(
  db: sqlight.Connection,
  session: String,
) -> Result(List(String), String) {
  store.rows(
    db,
    "SELECT payload FROM transcript WHERE session=? AND instr(payload,CAST('stored_data' AS BLOB))>0",
    [sqlight.text(session)],
    decode.field(0, decode.bit_array, decode.success),
  )
  |> result.map(fn(rows) { list.flat_map(rows, hashes) |> list.unique })
}

/// Deletes payloads no transcript row, pinned prompt, or cell still names.
/// A packed reference holds the hash text verbatim beside its `stored_data`
/// tag, so one read of the tagged rows answers for every candidate.
pub fn release(
  db: sqlight.Connection,
  candidates: List(String),
) -> Result(Nil, String) {
  use <- bool.guard(candidates == [], Ok(Nil))
  use tables <- result.try(store.rows(
    db,
    "SELECT name FROM sqlite_master WHERE type='table' AND name='cells'",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  let payload = decode.field(0, decode.bit_array, decode.success)
  use rows <- result.try(store.rows(
    db,
    "SELECT payload FROM transcript WHERE instr(payload,CAST('stored_data' AS BLOB))>0 UNION ALL SELECT pinned_context FROM sessions WHERE pinned_context IS NOT NULL",
    [],
    payload,
  ))
  use cells <- result.try(case tables {
    [] -> Ok([])
    _ ->
      store.rows(
        db,
        "SELECT payload FROM cells WHERE payload IS NOT NULL AND instr(payload,CAST('stored_data' AS BLOB))>0",
        [],
        payload,
      )
  })
  let named = referenced(list.append(rows, cells), candidates)
  candidates
  |> list.filter(fn(hash) { !list.contains(named, hash) })
  |> list.try_each(fn(hash) {
    store.run(db, "DELETE FROM images WHERE hash=?", [sqlight.text(hash)])
  })
}

/// Drops the images of tool outputs a committed compaction left out of the
/// prepared request: the row and its Python cell keep their text plus a
/// marker, and payloads nothing else names are released. User uploads stay;
/// their hashes are part of the saved compaction cut.
pub fn elide_evicted(
  ledger: store.Store,
  session: String,
  retained_calls: List(String),
) -> Result(Int, String) {
  store.query(ledger, fn(db) {
    use _ <- result.try(
      sqlight.exec("BEGIN IMMEDIATE", db)
      |> result.map_error(fn(e) { e.message }),
    )
    case elide_rows(db, session, retained_calls) {
      Ok(count) ->
        sqlight.exec("COMMIT", db)
        |> result.replace(count)
        |> result.map_error(fn(e) { e.message })
      Error(e) -> {
        let _ = sqlight.exec("ROLLBACK", db)
        Error(e)
      }
    }
  })
}

fn elide_rows(
  db: sqlight.Connection,
  session: String,
  retained_calls: List(String),
) -> Result(Int, String) {
  use rows <- result.try(
    sqlight.query(
      "SELECT seq,payload FROM transcript WHERE session=? AND instr(payload,CAST('tool_output' AS BLOB))>0",
      db,
      [sqlight.text(session)],
      {
        use seq <- decode.field(0, decode.int)
        use payload <- decode.field(1, decode.bit_array)
        decode.success(#(seq, payload))
      },
    )
    |> result.map_error(fn(e) { e.message }),
  )
  let evicted =
    list.filter_map(rows, fn(row) {
      case elide_tool_images(row.1) {
        Ok(#(call, payload, hashes)) ->
          case list.contains(retained_calls, call) {
            True -> Error(Nil)
            False -> Ok(#(row.0, session <> "/" <> call, payload, hashes))
          }
        Error(_) -> Error(Nil)
      }
    })
  use _ <- result.try(
    list.try_each(evicted, fn(row) {
      use _ <- result.try(write(
        db,
        "transcript",
        "seq",
        sqlight.int(row.0),
        row.2,
      ))
      elide_cell(db, row.1)
    }),
  )
  use _ <- result.try(release(
    db,
    list.flat_map(evicted, fn(row) { row.3 }) |> list.unique,
  ))
  Ok(list.length(evicted))
}

/// Remove image references from the cell when its tool output is evicted.
fn elide_cell(db: sqlight.Connection, id: String) -> Result(Nil, String) {
  let decoder = {
    use cell_id <- decode.field(0, decode.string)
    use payload <- decode.field(1, decode.bit_array)
    decode.success(#(cell_id, payload))
  }
  case
    sqlight.query(
      "SELECT id, payload FROM cells WHERE (id=? OR id LIKE ?) AND payload IS NOT NULL",
      db,
      [sqlight.text(id), sqlight.text(id <> "-%")],
      decoder,
    )
  {
    Ok(rows) ->
      list.try_each(rows, fn(row) {
        case elide_cell_images(row.1) {
          Ok(elided) -> write(db, "cells", "id", sqlight.text(row.0), elided)
          Error(_) -> Ok(Nil)
        }
      })
    _ -> Ok(Nil)
  }
}

fn write(
  db: sqlight.Connection,
  table: String,
  key: String,
  value: sqlight.Value,
  payload: BitArray,
) -> Result(Nil, String) {
  sqlight.query(
    "UPDATE " <> table <> " SET payload=? WHERE " <> key <> "=?",
    db,
    [sqlight.blob(payload), value],
    decode.dynamic,
  )
  |> result.replace(Nil)
  |> result.map_error(fn(e) { e.message })
}

@external(erlang, "albedo_conversation", "elide_tool_images")
fn elide_tool_images(
  payload: BitArray,
) -> Result(#(String, BitArray, List(String)), Nil)

@external(erlang, "albedo_native", "elide_cell_images")
fn elide_cell_images(payload: BitArray) -> Result(BitArray, Nil)

@external(erlang, "albedo_images", "externalize")
fn split(
  input: types.Input,
  read: fn(String) -> Result(String, Nil),
) -> #(types.Input, List(#(String, String)))

/// The candidates some payload names, found in one pass per payload.
@external(erlang, "albedo_images", "referenced")
fn referenced(
  payloads: List(BitArray),
  candidates: List(String),
) -> List(String)

@external(erlang, "albedo_images", "hashes")
fn hashes(payload: BitArray) -> List(String)

@external(erlang, "albedo_images", "encode_base64")
fn encode_base64(data: BitArray) -> String

@external(erlang, "albedo_images", "decode_legacy_base64")
fn decode_legacy_base64(data: String) -> Result(BitArray, Nil)
