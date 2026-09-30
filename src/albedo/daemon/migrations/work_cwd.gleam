//// Existing workspace column and index upgrade for the work ledger.

import albedo/daemon/store as storage
import gleam/result
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(
    storage.add_columns(db, "work", [
      #("cwd", "TEXT NOT NULL DEFAULT '__albedo_legacy__'"),
    ]),
  )
  storage.exec(db, "CREATE INDEX IF NOT EXISTS work_cwd_id ON work(cwd,id)")
}
