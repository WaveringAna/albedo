//// A model may close a vent it fixed: the row keeps its note on what fixed
//// it and the session that closed it, so the user can audit the closure.

import albedo/daemon/store as storage
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  storage.add_columns(db, "paperclips", [
    #("resolution", "TEXT NOT NULL DEFAULT ''"),
    #("resolved_by", "TEXT"),
  ])
}
