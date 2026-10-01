//// Ordered core data upgrades after schema initialisation, before sessions start.

import albedo/daemon/migrations/image_store
import albedo/daemon/migrations/transcript_classes
import albedo/daemon/store
import gleam/result

/// Upgrade image storage, then classify transcript rows. Extension upgrades
/// follow via the runtime; this module knows only core storage.
pub fn run(ledger: store.Store, backup: String) -> Result(Int, String) {
  use moved <- result.try(image_store.run(ledger, backup))
  use _ <- result.try(transcript_classes.run(ledger))
  Ok(moved)
}
