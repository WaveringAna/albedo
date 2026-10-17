//// A mail table created before requests or events checks its kind against a
//// list without them; SQLite cannot change a CHECK in place, so the table is
//// copied into the current schema once.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/result
import gleam/string
import sqlight

const copied =
  "id,recipient,sender,sender_name,kind,body,created_at,delivered_at,delivery_owner,attempts,last_error"

/// `schema` creates the current table, under the name `mail`.
pub fn apply(db: sqlight.Connection, schema: String) -> Result(Nil, String) {
  use definition <- result.try(store.rows(
    db,
    "SELECT sql FROM sqlite_master WHERE type='table' AND name='mail'",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  let current = case definition {
    [sql] ->
      string.contains(sql, "'request'") && string.contains(sql, "'event_turn'")
    _ -> True
  }
  case current {
    True -> Ok(Nil)
    False ->
      store.transaction(db, fn() {
        use _ <- result.try(store.exec(
          db,
          "ALTER TABLE mail RENAME TO mail_old_kinds",
        ))
        use _ <- result.try(store.exec(db, schema))
        use _ <- result.try(store.exec(
          db,
          "INSERT INTO mail("
            <> copied
            <> ") SELECT "
            <> copied
            <> " FROM mail_old_kinds",
        ))
        use _ <- result.try(store.exec(db, "DROP TABLE mail_old_kinds"))
        // The renamed table kept the indexes, so they went with it.
        store.exec(db, schema)
      })
  }
}
