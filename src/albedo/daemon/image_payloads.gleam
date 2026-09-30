//// Shared payload insertion for live writes and legacy transcript migration.

import albedo/daemon/store
import gleam/list
import sqlight

pub fn insert(
  db: sqlight.Connection,
  blobs: List(#(String, String)),
) -> Result(Nil, String) {
  list.try_each(blobs, fn(blob) {
    store.run(db, "INSERT OR IGNORE INTO images(hash,data) VALUES(?,?)", [
      sqlight.text(blob.0),
      sqlight.blob(decode_base64(blob.1)),
    ])
  })
}

@external(erlang, "albedo_images", "decode_base64")
fn decode_base64(data: String) -> BitArray
