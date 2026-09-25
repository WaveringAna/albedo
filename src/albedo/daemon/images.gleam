//// Image payloads stored once by content hash, out of transcript rows.
////
//// A transcript row keeps an image's hash and metadata; its base64 text lives
//// in `images`. Loading a session therefore reads references, and a payload is
//// read only while a request body is written (albedo_openai_transport.erl).
//// Rows are content-addressed, so forks and repeated screenshots share one copy.

import albedo/daemon/store
import albedo/openai_api/types
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

pub const schema = "CREATE TABLE IF NOT EXISTS images(hash TEXT PRIMARY KEY,data TEXT NOT NULL); CREATE TABLE IF NOT EXISTS migrations(name TEXT PRIMARY KEY,applied_at INTEGER NOT NULL);"

/// Fetches a stored payload. Never call the result from inside `store.query`:
/// the read is itself a store query, and the store runs one at a time.
pub fn reader(ledger: store.Store) -> fn(String) -> Result(String, Nil) {
  fn(hash) { store.query(ledger, fn(db) { read(db, hash) }) }
}

fn read(db: sqlight.Connection, hash: String) -> Result(String, Nil) {
  case
    sqlight.query(
      "SELECT data FROM images WHERE hash=?",
      db,
      [sqlight.text(hash)],
      decode.field(0, decode.string, decode.success),
    )
  {
    Ok([data]) -> Ok(data)
    _ -> Error(Nil)
  }
}

/// The input with its inline images replaced by stored references, after
/// writing their payloads. Runs inside the caller's transaction.
pub fn externalize(
  db: sqlight.Connection,
  input: types.Input,
  read: fn(String) -> Result(String, Nil),
) -> Result(types.Input, String) {
  let #(stored, blobs) = split(input, read)
  use _ <- result.try(insert(db, blobs))
  Ok(stored)
}

fn insert(
  db: sqlight.Connection,
  blobs: List(#(String, String)),
) -> Result(Nil, String) {
  list.try_each(blobs, fn(blob) {
    sqlight.query(
      "INSERT OR IGNORE INTO images(hash,data) VALUES(?,?)",
      db,
      [sqlight.text(blob.0), sqlight.text(blob.1)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

/// Hashes the given session's rows reference, read before those rows are
/// deleted so `release` can drop payloads nothing else needs.
pub fn session_hashes(
  db: sqlight.Connection,
  session: String,
) -> Result(List(String), String) {
  sqlight.query(
    "SELECT payload FROM transcript WHERE session=? AND instr(payload,CAST('stored_data' AS BLOB))>0",
    db,
    [sqlight.text(session)],
    decode.field(0, decode.bit_array, decode.success),
  )
  |> result.map(fn(rows) { list.flat_map(rows, hashes) |> list.unique })
  |> result.map_error(fn(e) { e.message })
}

/// Deletes payloads no transcript row or pinned prompt still names. A packed
/// reference holds the hash text verbatim, so a byte search finds every user.
pub fn release(
  db: sqlight.Connection,
  candidates: List(String),
) -> Result(Nil, String) {
  list.try_each(candidates, fn(hash) {
    sqlight.query(
      "DELETE FROM images WHERE hash=?1 AND NOT EXISTS(SELECT 1 FROM transcript WHERE instr(payload,CAST(?1 AS BLOB))>0) AND NOT EXISTS(SELECT 1 FROM sessions WHERE pinned_context IS NOT NULL AND instr(pinned_context,CAST(?1 AS BLOB))>0)",
      db,
      [sqlight.text(hash)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

/// Moves inline images in existing transcript rows into `images`, once per
/// database. The database is first copied to `backup` with VACUUM INTO. Rows
/// are rewritten a page at a time, each page in its own transaction, so an
/// interrupted run resumes where it stopped (a rewritten row has nothing inline).
pub fn migrate(ledger: store.Store, backup: String) -> Result(Int, String) {
  let read = reader(ledger)
  use applied <- result.try(
    store.query(ledger, fn(db) {
      sqlight.query(
        "SELECT 1 FROM migrations WHERE name='image_store'",
        db,
        [],
        decode.dynamic,
      )
      |> result.map(fn(rows) { rows != [] })
      |> result.map_error(fn(e) { e.message })
    }),
  )
  case applied {
    True -> Ok(0)
    False -> {
      use pending <- result.try(
        store.query(ledger, fn(db) {
          sqlight.query(
            "SELECT count(*) FROM transcript WHERE instr(payload,CAST('user_image' AS BLOB))>0 OR instr(payload,CAST('tool_output' AS BLOB))>0",
            db,
            [],
            decode.field(0, decode.int, decode.success),
          )
          |> result.map_error(fn(e) { e.message })
        }),
      )
      use _ <- result.try(case pending {
        [0] -> Ok(Nil)
        _ -> {
          ensure_dir(backup)
          store.query(ledger, fn(db) {
            sqlight.query(
              "VACUUM INTO ?",
              db,
              [sqlight.text(backup)],
              decode.dynamic,
            )
            |> result.replace(Nil)
            |> result.map_error(fn(e) {
              "image store backup failed: " <> e.message
            })
          })
        }
      })
      use moved <- result.try(migrate_pages(ledger, read, -1, 0))
      use _ <- result.try(
        store.query(ledger, fn(db) {
          sqlight.query(
            "INSERT OR IGNORE INTO migrations(name,applied_at) VALUES('image_store',unixepoch())",
            db,
            [],
            decode.dynamic,
          )
          |> result.replace(Nil)
          |> result.map_error(fn(e) { e.message })
        }),
      )
      Ok(moved)
    }
  }
}

/// Rows per migration transaction; a page of screenshot rows is tens of MB.
const migrate_page_rows = 16

fn migrate_pages(
  ledger: store.Store,
  read: fn(String) -> Result(String, Nil),
  after: Int,
  moved: Int,
) -> Result(Int, String) {
  let page =
    store.query(ledger, fn(db) {
      use rows <- result.try(
        sqlight.query(
          "SELECT seq,payload FROM transcript WHERE seq>? AND (instr(payload,CAST('user_image' AS BLOB))>0 OR instr(payload,CAST('tool_output' AS BLOB))>0) ORDER BY seq LIMIT ?",
          db,
          [sqlight.int(after), sqlight.int(migrate_page_rows)],
          {
            use seq <- decode.field(0, decode.int)
            use payload <- decode.field(1, decode.bit_array)
            decode.success(#(seq, payload))
          },
        )
        |> result.map_error(fn(e) { e.message }),
      )
      use _ <- result.try(
        sqlight.exec("BEGIN IMMEDIATE", db)
        |> result.map_error(fn(e) { e.message }),
      )
      let written =
        list.try_fold(rows, 0, fn(count, row) {
          case migrate_row(row.1, read) {
            Keep -> Ok(count)
            Rewrite(payload, blobs) -> {
              use _ <- result.try(insert(db, blobs))
              sqlight.query(
                "UPDATE transcript SET payload=? WHERE seq=?",
                db,
                [sqlight.blob(payload), sqlight.int(row.0)],
                decode.dynamic,
              )
              |> result.replace(count + 1)
              |> result.map_error(fn(e) { e.message })
            }
          }
        })
      case written {
        Ok(count) -> {
          use _ <- result.try(
            sqlight.exec("COMMIT", db)
            |> result.map_error(fn(e) { e.message }),
          )
          Ok(#(count, list.last(rows) |> result.map(fn(row) { row.0 })))
        }
        Error(e) -> {
          let _ = sqlight.exec("ROLLBACK", db)
          Error(e)
        }
      }
    })
  case page {
    Error(e) -> Error("image store migration failed: " <> e)
    Ok(#(count, Ok(last))) -> migrate_pages(ledger, read, last, moved + count)
    Ok(#(count, Error(_))) -> Ok(moved + count)
  }
}

type Migration {
  Keep
  Rewrite(payload: BitArray, blobs: List(#(String, String)))
}

@external(erlang, "albedo_images", "externalize")
fn split(
  input: types.Input,
  read: fn(String) -> Result(String, Nil),
) -> #(types.Input, List(#(String, String)))

@external(erlang, "albedo_images", "hashes")
fn hashes(payload: BitArray) -> List(String)

@external(erlang, "albedo_images", "migrate")
fn migrate_row(
  payload: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Migration

@external(erlang, "albedo_images", "ensure_dir")
fn ensure_dir(path: String) -> Nil
