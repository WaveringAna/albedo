import albedo/daemon/store
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.add_columns(db, "paperclips", [
    #("revision", "INTEGER NOT NULL DEFAULT 1"),
  ])
}
