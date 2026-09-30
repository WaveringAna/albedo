//// The user's answer to a vent becomes durable: stored on the row, so a
//// reply survives even when the session that filed the vent is gone and
//// the note could not be delivered.

import albedo/daemon/store as storage
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  storage.add_columns(db, "paperclips", [
    #("reply", "TEXT NOT NULL DEFAULT ''"),
  ])
}
