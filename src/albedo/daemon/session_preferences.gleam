//// Import the previous per-session files once, then keep session choices in
//// the database. The file owner removes imported fields after the SQL commit.

import albedo/daemon/session_catalog
import albedo/daemon/session_configuration
import albedo/daemon/store
import gleam/dict
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import sqlight

pub type PreferencesImport {
  PreferencesImport(
    pinned: List(String),
    archived: List(String),
    opens: List(#(String, Int)),
    choices: List(#(String, String, String, Bool)),
  )
}

/// Decode the previous documents before the native owner calls the SQL import.
pub fn decode_import(
  picker: Dynamic,
  capabilities: Dynamic,
) -> Result(PreferencesImport, Nil) {
  let picker_decoder = {
    use pinned <- decode.optional_field("pinned", [], identifiers())
    use archived <- decode.optional_field("archived", [], identifiers())
    use opens <- decode.optional_field(
      "opens",
      dict.new(),
      decode.dict(identifier(), count()),
    )
    decode.success(#(pinned, archived, opens))
  }
  use #(pinned, archived, opens) <- result.try(
    decode.run(picker, picker_decoder) |> result.replace_error(Nil),
  )
  let scopes = {
    use skills <- decode.optional_field(
      "skills",
      dict.new(),
      decode.dict(identifier(), decode.bool),
    )
    use instructions <- decode.optional_field(
      "instructions",
      dict.new(),
      decode.dict(identifier(), decode.bool),
    )
    use mcp <- decode.optional_field(
      "mcp",
      dict.new(),
      decode.dict(identifier(), decode.bool),
    )
    decode.success([
      #("skills", skills),
      #("instructions", instructions),
      #("mcp", mcp),
    ])
  }
  let choices_decoder = {
    use sessions <- decode.optional_field(
      "sessions",
      dict.new(),
      decode.dict(identifier(), scopes),
    )
    decode.success(sessions)
  }
  use sessions <- result.try(
    decode.run(capabilities, choices_decoder) |> result.replace_error(Nil),
  )
  let choices =
    sessions
    |> dict.to_list
    |> list.flat_map(fn(entry) {
      let #(session, kinds) = entry
      list.flat_map(kinds, fn(kind) {
        kind.1
        |> dict.to_list
        |> list.map(fn(choice) { #(session, kind.0, choice.0, choice.1) })
      })
    })
  Ok(PreferencesImport(pinned, archived, dict.to_list(opens), choices))
}

fn identifier() -> decode.Decoder(String) {
  use value <- decode.then(decode.string)
  case string.byte_size(value) > 0 && string.byte_size(value) <= 512 {
    True -> decode.success(value)
    False -> decode.failure("", "session preference identifier")
  }
}

fn identifiers() -> decode.Decoder(List(String)) {
  use values <- decode.then(decode.list(identifier()))
  let unique =
    list.fold(values, dict.new(), fn(unique, id) {
      dict.insert(unique, id, Nil)
    })
  case list.length(values) == dict.size(unique) {
    True -> decode.success(values)
    False -> decode.failure([], "unique session preference identifiers")
  }
}

fn count() -> decode.Decoder(Int) {
  use value <- decode.then(decode.int)
  case value >= 0 {
    True -> decode.success(value)
    False -> decode.failure(0, "nonnegative session opening count")
  }
}

pub fn migrate(
  home: String,
  inventory: session_catalog.Inventory,
) -> Result(Nil, String) {
  migrate_files(home, fn(saved) {
    let ledger = inventory.ledger
    use imported <- result.try(
      store.query(ledger, fn(db) {
        use _ <- result.try(store.exec(
          db,
          "CREATE TABLE IF NOT EXISTS session_preferences_import(version INTEGER PRIMARY KEY CHECK(version=1))",
        ))
        store.rows(
          db,
          "SELECT version FROM session_preferences_import",
          [],
          decode.field(0, decode.int, decode.success),
        )
      }),
    )
    case imported {
      [_] -> Ok(Nil)
      _ -> {
        let grouped =
          list.fold(saved.choices, dict.new(), fn(groups, entry) {
            let prior = dict.get(groups, entry.0) |> result.unwrap([])
            dict.insert(groups, entry.0, [#(entry.1, entry.2, entry.3), ..prior])
          })
        use choices <- result.try(
          list.try_fold(dict.to_list(grouped), [], fn(choices, entry) {
            let #(session, entries) = entry
            use exists <- result.try(store.read(
              ledger,
              "SELECT id FROM sessions WHERE id=?",
              [sqlight.text(session)],
              decode.field(0, decode.string, decode.success),
            ))
            case exists {
              [] -> Ok(choices)
              _ -> {
                use catalog <- result.try(session_catalog.inspect(
                  home,
                  inventory,
                  session,
                ))
                let resolved =
                  list.map(entries, fn(entry) {
                    let #(kind, key, enabled) = entry
                    let candidate_kind = case kind {
                      "skills" -> "skill"
                      "instructions" -> "instruction"
                      _ -> kind
                    }
                    let candidate =
                      catalog.candidates
                      |> list.find(fn(candidate) {
                        candidate.kind == candidate_kind
                        && candidate.preference_key == Some(key)
                      })
                      |> result.map(fn(candidate) { candidate.id })
                      |> result.unwrap(
                        "unresolved-" <> fingerprint(kind <> ":" <> key),
                      )
                    #(
                      session,
                      session_configuration.Choice(
                        kind,
                        candidate,
                        key,
                        enabled,
                      ),
                    )
                  })
                Ok(list.append(resolved, choices))
              }
            }
          }),
        )
        store.query(ledger, fn(db) {
          store.transaction(db, fn() {
            use _ <- result.try(
              list.try_each(
                list.index_map(saved.pinned, fn(id, order) { #(id, order) }),
                fn(pin) {
                  store.run(
                    db,
                    "UPDATE sessions SET pinned=1,pin_order=? WHERE id=?",
                    [sqlight.int(pin.1), sqlight.text(pin.0)],
                  )
                },
              ),
            )
            use _ <- result.try(
              list.try_each(saved.archived, fn(id) {
                store.run(db, "UPDATE sessions SET archived=1 WHERE id=?", [
                  sqlight.text(id),
                ])
              }),
            )
            use _ <- result.try(
              list.try_each(saved.opens, fn(entry) {
                store.run(db, "UPDATE sessions SET opens=? WHERE id=?", [
                  sqlight.int(entry.1),
                  sqlight.text(entry.0),
                ])
              }),
            )
            use _ <- result.try(
              list.try_each(choices, fn(entry) {
                let choice = entry.1
                store.run(
                  db,
                  "INSERT INTO session_selection(session,kind,candidate,preference_key,enabled) VALUES(?,?,?,?,?)",
                  [
                    sqlight.text(entry.0),
                    sqlight.text(choice.kind),
                    sqlight.text(choice.candidate),
                    sqlight.text(choice.preference_key),
                    sqlight.int(case choice.enabled {
                      True -> 1
                      False -> 0
                    }),
                  ],
                )
              }),
            )
            use _ <- result.try(store.exec(
              db,
              "UPDATE sessions SET config_revision=config_revision+1 WHERE pinned=1 OR archived=1 OR EXISTS(SELECT 1 FROM session_selection WHERE session=sessions.id)",
            ))
            store.exec(
              db,
              "INSERT INTO session_preferences_import(version) VALUES(1)",
            )
          })
        })
      }
    }
  })
}

@external(erlang, "albedo_session_preferences", "migrate")
fn migrate_files(
  home: String,
  apply: fn(PreferencesImport) -> Result(Nil, String),
) -> Result(Nil, String)

@external(erlang, "albedo_session_catalog", "fingerprint")
fn fingerprint(value: String) -> String
