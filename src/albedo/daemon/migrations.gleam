//// Ordered data upgrades after core schema initialisation, before sessions start.
//// Schema column upgrades remain in their owning initialisers.

import albedo/daemon/migrations/cell_images
import albedo/daemon/migrations/image_store
import albedo/daemon/store
import gleam/result

/// Transcript references, image TEXT to BLOB, then cell references. Both image
/// steps share the startup backup path. Returns rewritten transcript/cell counts.
pub fn run(ledger: store.Store, backup: String) -> Result(#(Int, Int), String) {
  use transcript_moved <- result.try(image_store.run(ledger, backup))
  use cells_moved <- result.try(cell_images.run(ledger, backup))
  Ok(#(transcript_moved, cells_moved))
}
