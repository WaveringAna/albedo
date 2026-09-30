//// Existing VACUUM INTO backup behavior for image migrations.

import albedo/daemon/store
import gleam/result
import sqlight

pub fn image_store(ledger: store.Store, backup: String) -> Result(Nil, String) {
  case backup_exists(backup) {
    True -> Ok(Nil)
    False -> {
      ensure_dir(backup)
      store.query(ledger, fn(db) {
        store.run(db, "VACUUM INTO ?", [sqlight.text(backup)])
      })
      |> result.map_error(fn(e) { "image store backup failed: " <> e })
    }
  }
}

pub fn cell_images(
  db: sqlight.Connection,
  path: String,
) -> Result(Nil, String) {
  ensure_dir(path)
  case backup_exists(path) {
    True -> Ok(Nil)
    False -> store.run(db, "VACUUM INTO ?", [sqlight.text(path)])
  }
}

@external(erlang, "albedo_images", "ensure_dir")
fn ensure_dir(path: String) -> Nil

@external(erlang, "albedo_images", "backup_exists")
fn backup_exists(path: String) -> Bool
