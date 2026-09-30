//// Existing transcript reference and image BLOB migrations, in that order.

import albedo/daemon/image_payloads
import albedo/daemon/images
import albedo/daemon/migrations/backup as snapshot
import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

/// Moves inline images in existing transcript rows into `images`, once per
/// database. The database is first copied to `backup` with VACUUM INTO. Rows
/// are rewritten a page at a time, each page in its own transaction, so an
/// interrupted run resumes where it stopped (a rewritten row has nothing inline).
pub fn run(ledger: store.Store, backup: String) -> Result(Int, String) {
  use moved <- result.try(migrate_legacy(ledger, backup))
  use _ <- result.try(migrate_blobs(ledger, backup))
  Ok(moved)
}

fn migrate_legacy(ledger: store.Store, backup: String) -> Result(Int, String) {
  let read = images.reader(ledger)
  use applied <- result.try(
    store.read(
      ledger,
      "SELECT 1 FROM migrations WHERE name='image_store'",
      [],
      decode.dynamic,
    )
    |> result.map(fn(rows) { rows != [] }),
  )
  case applied {
    True -> Ok(0)
    False -> {
      use pending <- result.try(store.read(
        ledger,
        "SELECT count(*) FROM transcript WHERE instr(payload,CAST('user_image' AS BLOB))>0 OR instr(payload,CAST('tool_output' AS BLOB))>0",
        [],
        decode.field(0, decode.int, decode.success),
      ))
      use _ <- result.try(case pending {
        [0] -> Ok(Nil)
        _ -> {
          snapshot.image_store(ledger, backup)
        }
      })
      use moved <- result.try(migrate_pages(ledger, read, -1, 0))
      use _ <- result.try(
        store.write(
          ledger,
          "INSERT OR IGNORE INTO migrations(name,applied_at) VALUES('image_store',unixepoch())",
          [],
        ),
      )
      Ok(moved)
    }
  }
}

/// Existing installations used TEXT for the base64 data. Convert in bounded
/// transactions after taking a copy of the database. SQLite's BLOB affinity
/// does not convert an existing TEXT value on its own.
fn migrate_blobs(ledger: store.Store, backup: String) -> Result(Nil, String) {
  use pending <- result.try(store.read(
    ledger,
    "SELECT count(*) FROM images WHERE typeof(data)='text'",
    [],
    decode.field(0, decode.int, decode.success),
  ))
  case pending {
    [0] -> Ok(Nil)
    _ -> {
      use _ <- result.try(snapshot.image_store(ledger, backup))
      migrate_blob_pages(ledger)
    }
  }
}

fn migrate_blob_pages(ledger: store.Store) -> Result(Nil, String) {
  let page =
    store.query(ledger, fn(db) {
      use rows <- result.try(
        store.rows(
          db,
          "SELECT hash,data FROM images WHERE typeof(data)='text' LIMIT ?",
          [sqlight.int(migrate_page_rows)],
          {
            use hash <- decode.field(0, decode.string)
            use data <- decode.field(1, decode.string)
            decode.success(#(hash, data))
          },
        ),
      )
      use _ <- result.try(
        store.transaction(db, fn() {
          list.try_each(rows, fn(row) {
            case decode_legacy_base64(row.1) {
              Ok(bytes) ->
                store.run(
                  db,
                  "UPDATE images SET data=? WHERE hash=? AND typeof(data)='text'",
                  [sqlight.blob(bytes), sqlight.text(row.0)],
                )
              Error(_) -> Error("invalid base64 image at hash " <> row.0)
            }
          })
        }),
      )
      Ok(list.length(rows))
    })
  case page {
    Ok(0) -> Ok(Nil)
    Ok(_) -> migrate_blob_pages(ledger)
    Error(e) -> Error("image blob migration failed: " <> e)
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
        store.rows(
          db,
          "SELECT seq,payload FROM transcript WHERE seq>? AND (instr(payload,CAST('user_image' AS BLOB))>0 OR instr(payload,CAST('tool_output' AS BLOB))>0) ORDER BY seq LIMIT ?",
          [sqlight.int(after), sqlight.int(migrate_page_rows)],
          {
            use seq <- decode.field(0, decode.int)
            use payload <- decode.field(1, decode.bit_array)
            decode.success(#(seq, payload))
          },
        ),
      )
      use count <- result.try(
        store.transaction(db, fn() {
          list.try_fold(rows, 0, fn(count, row) {
            case migrate_row(row.1, read) {
              Keep -> Ok(count)
              Rewrite(payload, blobs) -> {
                use _ <- result.try(image_payloads.insert(db, blobs))
                store.run(db, "UPDATE transcript SET payload=? WHERE seq=?", [
                  sqlight.blob(payload),
                  sqlight.int(row.0),
                ])
                |> result.replace(count + 1)
              }
            }
          })
        }),
      )
      Ok(#(count, list.last(rows) |> result.map(fn(row) { row.0 })))
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

@external(erlang, "albedo_images", "migrate")
fn migrate_row(
  payload: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Migration

@external(erlang, "albedo_images", "decode_legacy_base64")
fn decode_legacy_base64(data: String) -> Result(BitArray, Nil)
