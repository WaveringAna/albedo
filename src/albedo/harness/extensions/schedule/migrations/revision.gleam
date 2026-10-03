import albedo/daemon/store
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.add_columns(db, "schedules", [
    #("revision", "INTEGER NOT NULL DEFAULT 1"),
    #("created_at", "TEXT"),
    #("updated_at", "TEXT"),
  ])
}
