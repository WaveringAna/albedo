//// The ledger became global: the workspace index no longer serves any read
//// and only taxes writes, so existing stores drop it.

import albedo/daemon/store as storage
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  storage.exec(db, "DROP INDEX IF EXISTS paperclips_cwd")
}
