//// Existing title-column upgrade for the paperclips ledger.

import albedo/daemon/store as storage
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  storage.add_columns(db, "paperclips", [
    #("title", "TEXT NOT NULL DEFAULT ''"),
  ])
}
