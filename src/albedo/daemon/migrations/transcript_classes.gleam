//// Resumable classification of old payloads before session processes start.

import albedo/daemon/conversation
import albedo/daemon/store
import gleam/dynamic/decode
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
            "SELECT seq,payload,session FROM transcript WHERE row_class IS NULL ORDER BY seq LIMIT 128",
            [],
            {
              use seq <- decode.field(0, decode.int)
              use payload <- decode.field(1, decode.bit_array)
              use session <- decode.field(2, decode.string)
              decode.success(#(seq, payload, session))
            },
          ),
        )
        use _ <- result.try(
          list.try_each(rows, fn(row) {
            case classify(row.1) {
              Ok(class) ->
                store.run(db, "UPDATE transcript SET row_class=? WHERE seq=?", [
                  sqlight.text(class),
                  sqlight.int(row.0),
                ])
              // Healing writes the note's class with it.
              Error(Nil) ->
                conversation.heal_in(db, row.2, row.0, row.1)
                |> result.replace(Nil)
            }
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
