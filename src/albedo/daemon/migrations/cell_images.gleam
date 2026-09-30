//// Existing migration of inline cell screenshots into shared image payloads.

import albedo/daemon/images
import albedo/daemon/migrations/backup as snapshot
import albedo/daemon/store
import albedo/harness/extensions/python/kernel as python
import gleam/dynamic/decode
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import sqlight

/// Move legacy inline cell screenshots into the shared image store. Each page
/// commits independently; an interrupted startup rechecks the remaining rows.
pub fn run(storage: store.Store, backup: String) -> Result(Int, String) {
  use tables <- result.try(store.read(
    storage,
    "SELECT 1 FROM sqlite_master WHERE type='table' AND name='cells'",
    [],
    decode.dynamic,
  ))
  case tables {
    [] -> Ok(0)
    _ -> migrate_existing_cells(storage, backup)
  }
}

fn migrate_existing_cells(
  storage: store.Store,
  backup: String,
) -> Result(Int, String) {
  use applied <- result.try(store.read(
    storage,
    "SELECT 1 FROM migrations WHERE name='cell_images'",
    [],
    decode.dynamic,
  ))
  case applied {
    [] -> migrate_image_pages(storage, backup, 0, 0)
    _ -> Ok(0)
  }
}

fn migrate_image_pages(
  storage: store.Store,
  backup: String,
  after: Int,
  moved: Int,
) -> Result(Int, String) {
  let page =
    store.query(storage, fn(db) {
      use rows <- result.try(
        store.rows(
          db,
          "SELECT rowid,payload FROM cells WHERE rowid>? AND payload IS NOT NULL AND instr(payload,CAST('image' AS BLOB))>0 ORDER BY rowid LIMIT 16",
          [sqlight.int(after)],
          {
            use rowid <- decode.field(0, decode.int)
            use payload <- decode.field(1, decode.bit_array)
            decode.success(#(rowid, payload))
          },
        ),
      )
      case rows {
        [] ->
          store.run(
            db,
            "INSERT OR IGNORE INTO migrations(name,applied_at) VALUES('cell_images',unixepoch())",
            [],
          )
          |> result.replace(#(0, None))
        _ -> {
          use _ <- result.try(
            case
              moved == 0 && list.any(rows, fn(row) { has_inline_image(row.1) })
            {
              True -> snapshot.cell_images(db, backup)
              False -> Ok(Nil)
            },
          )
          use count <- result.try(
            store.transaction(db, fn() {
              list.try_fold(rows, 0, fn(count, row) {
                case has_inline_image(row.1) {
                  False -> Ok(count)
                  True -> {
                    use decoded <- result.try(
                      unpack(row.1, fn(_) { Error(Nil) })
                      |> result.replace_error("invalid legacy cell image"),
                    )
                    case decoded {
                      Ok(outcome) -> {
                        use stored <- result.try(images.store_cell_images(
                          db,
                          outcome.images,
                        ))
                        use _ <- result.try(
                          store.run(
                            db,
                            "UPDATE cells SET payload=? WHERE rowid=?",
                            [
                              sqlight.blob(
                                pack(Ok(
                                  python.Outcome(..outcome, images: stored),
                                )),
                              ),
                              sqlight.int(row.0),
                            ],
                          ),
                        )
                        Ok(count + 1)
                      }
                      Error(_) -> Error("invalid legacy cell result")
                    }
                  }
                }
              })
            }),
          )
          let assert Ok(last) = list.last(rows)
          Ok(#(count, Some(last.0)))
        }
      }
    })
  case page {
    Error(error) -> Error("cell image migration failed: " <> error)
    Ok(#(count, Some(last))) ->
      migrate_image_pages(storage, backup, last, moved + count)
    Ok(#(_, None)) -> Ok(moved)
  }
}

@external(erlang, "albedo_native", "pack_cell")
fn pack(outcome: Result(python.Outcome, python.Error)) -> BitArray

@external(erlang, "albedo_native", "inline_cell")
fn has_inline_image(payload: BitArray) -> Bool

@external(erlang, "albedo_native", "unpack_cell")
fn unpack(
  payload: BitArray,
  read: fn(String) -> Result(String, Nil),
) -> Result(Result(python.Outcome, python.Error), Nil)
