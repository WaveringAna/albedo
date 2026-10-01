//// Detached kernels outlive the daemon, so what reaches them must too: the
//// tables behind python/link, created after the cells journal.

import albedo/harness/extensions/python/link
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  link.apply(db)
}
