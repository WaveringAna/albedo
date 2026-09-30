//// Ordered core data upgrades after schema initialisation, before sessions start.

import albedo/daemon/migrations/image_store
import albedo/daemon/store

/// Transcript references and image TEXT to BLOB. Extension upgrades follow via
/// the runtime; this module knows only core storage.
pub fn run(ledger: store.Store, backup: String) -> Result(Int, String) {
  image_store.run(ledger, backup)
}
