//// Resumable classification of old payloads before session processes start.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import sqlight

pub fn run(ledger: store.Store) -> Result(Nil, String) {
  use _ <- result.try(
    store.query(ledger, fn(db) {
      store.exec(
        db,
        "CREATE INDEX IF NOT EXISTS transcript_pending_class ON transcript(seq) WHERE row_class IS NULL; CREATE INDEX IF NOT EXISTS transcript_users ON transcript(session,seq) WHERE row_class IN ('user','image_fit'); CREATE INDEX IF NOT EXISTS transcript_fits ON transcript(session,seq) WHERE row_class='image_fit'",
      )
    }),
  )
  pages(ledger)
}

fn pages(ledger: store.Store) -> Result(Nil, String) {
  use count <- result.try(
    store.query(ledger, fn(db) {
      store.transaction(db, fn() {
        use rows <- result.try(
          store.rows(
            db,
            "SELECT seq,payload FROM transcript WHERE row_class IS NULL ORDER BY seq LIMIT 128",
            [],
            {
              use seq <- decode.field(0, decode.int)
              use payload <- decode.field(1, decode.bit_array)
              decode.success(#(seq, payload))
            },
          ),
        )
        use _ <- result.try(
          list.try_each(rows, fn(row) {
            use class <- result.try(
              classify(row.1)
              |> result.replace_error(
                "cannot classify corrupt transcript row #"
                <> int.to_string(row.0),
              ),
            )
            store.run(db, "UPDATE transcript SET row_class=? WHERE seq=?", [
              sqlight.text(class),
              sqlight.int(row.0),
            ])
          }),
        )
        Ok(list.length(rows))
      })
    }),
  )
  case count {
    0 -> Ok(Nil)
    _ -> pages(ledger)
  }
}

@external(erlang, "albedo_conversation", "classify")
fn classify(bytes: BitArray) -> Result(String, Nil)
