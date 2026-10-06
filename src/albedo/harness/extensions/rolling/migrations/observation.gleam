//// Rolling kept a copy of each request's observation in its own table and
//// read it straight back; the observation now travels with the prepared
//// request alone, so existing stores drop the table.

import albedo/daemon/store
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.exec(db, "DROP TABLE IF EXISTS rolling_compaction_observation")
}
