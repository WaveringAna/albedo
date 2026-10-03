//// Durable editable session state. Callers validate runtime policy before
//// committing a candidate on the shared store connection.

import albedo/daemon/family
import albedo/daemon/operations
import albedo/daemon/store
import albedo/daemon/usage
import albedo/openai_api/types
import gleam/dict.{type Dict}
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Preferences {
  Preferences(pinned: Bool, pin_order: Option(Int), archived: Bool, opens: Int)
}

pub type Selection {
  Selection(
    extensions: Dict(String, Bool),
    skills: Dict(String, Bool),
    instructions: Dict(String, Bool),
    mcp: Dict(String, Bool),
  )
}

pub type Configuration {
  Configuration(
    id: String,
    name: Option(String),
    automatic_name: String,
    workspace: String,
    provider_profile: String,
    model: String,
    effort: Option(String),
    revision: Int,
    family: family.Facts,
    preferences: Preferences,
    selection: Selection,
  )
}

pub type Version {
  Version(revision: Int, family_revision: Int)
}

pub type SelectionPatch {
  SelectionPatch(
    extensions: Option(Option(Dict(String, Option(Bool)))),
    skills: Option(Option(Dict(String, Option(Bool)))),
    instructions: Option(Option(Dict(String, Option(Bool)))),
    mcp: Option(Option(Dict(String, Option(Bool)))),
  )
}

pub type Patch {
  Patch(
    name: Option(Option(String)),
    provider_profile: Option(String),
    model: Option(String),
    effort: Option(Option(String)),
    pinned: Option(Bool),
    archived: Option(Bool),
    selection: SelectionPatch,
    catalog_revision: Option(String),
  )
}

pub type Visit {
  Visit(visit_id: String, session_id: String, opens: Int)
}

/// Catalog identity and the key runtime loaders use are captured together.
pub type Choice {
  Choice(kind: String, candidate: String, preference_key: String, enabled: Bool)
}

pub type Edit {
  Edit(
    expected: Version,
    candidate: Configuration,
    protocol: types.Protocol,
    choices: List(Choice),
  )
}

pub fn display_name(value: Configuration) -> String {
  case value.name, value.family.member {
    Some(name), _ -> name
    None, Some(member) -> member.name
    None, None -> value.automatic_name
  }
  |> clean_name
  |> option.unwrap("")
}

/// Human session names are one display-safe line. Their creation intent remains
/// exact; names replace controls and invisibles, fold whitespace, and contain
/// at most 4096 Unicode scalars even when one grapheme contains many marks.
pub fn clean_name(name: String) -> Option(String) {
  let assert Ok(space) = string.utf_codepoint(32)
  let clean =
    name
    |> string.to_utf_codepoints
    |> list.map(fn(codepoint) {
      let value = string.utf_codepoint_to_int(codepoint)
      case
        value <= 31
        || { value >= 127 && value <= 159 }
        || value == 173
        || value == 8203
        || { value >= 8206 && value <= 8207 }
        || { value >= 8232 && value <= 8238 }
        || { value >= 8288 && value <= 8297 }
        || value == 65_279
      {
        True -> space
        False -> codepoint
      }
    })
    |> string.from_utf_codepoints
    |> string.trim
    |> string.split(" ")
    |> list.filter(fn(part) { part != "" })
    |> string.join(" ")
    |> string.to_utf_codepoints
    |> list.take(4096)
    |> string.from_utf_codepoints
    |> string.trim
  case clean {
    "" -> None
    _ -> Some(clean)
  }
}

pub fn apply(current: Configuration, patch: Patch) -> Configuration {
  let name = option.unwrap(patch.name, current.name)
  let name = option.then(name, clean_name)
  let preferences =
    Preferences(
      ..current.preferences,
      pinned: option.unwrap(patch.pinned, current.preferences.pinned),
      archived: option.unwrap(patch.archived, current.preferences.archived),
    )
  Configuration(
    ..current,
    name: name,
    provider_profile: option.unwrap(
      patch.provider_profile,
      current.provider_profile,
    ),
    model: option.unwrap(patch.model, current.model),
    effort: option.unwrap(patch.effort, current.effort),
    preferences: preferences,
    selection: Selection(
      apply_choices(current.selection.extensions, patch.selection.extensions),
      apply_choices(current.selection.skills, patch.selection.skills),
      apply_choices(
        current.selection.instructions,
        patch.selection.instructions,
      ),
      apply_choices(current.selection.mcp, patch.selection.mcp),
    ),
  )
}

fn apply_choices(
  current: Dict(String, Bool),
  patch: Option(Option(Dict(String, Option(Bool)))),
) -> Dict(String, Bool) {
  case patch {
    None -> current
    Some(None) -> dict.new()
    Some(Some(changes)) ->
      dict.fold(changes, current, fn(choices, key, choice) {
        case choice {
          Some(enabled) -> dict.insert(choices, key, enabled)
          None -> dict.delete(choices, key)
        }
      })
  }
}

pub fn choices_in(
  db: sqlight.Connection,
  session: String,
) -> Result(List(Choice), String) {
  store.rows(
    db,
    "SELECT kind,candidate,preference_key,enabled FROM session_selection WHERE session=? UNION ALL SELECT 'extensions',name,name,enabled FROM session_extensions WHERE session=?",
    [sqlight.text(session), sqlight.text(session)],
    {
      use kind <- decode.field(0, decode.string)
      use candidate <- decode.field(1, decode.string)
      use key <- decode.field(2, decode.string)
      use enabled <- decode.field(3, sqlight.decode_bool())
      decode.success(Choice(kind, candidate, key, enabled))
    },
  )
}

/// Runtime validation precedes this call. Recheck the captured validators
/// inside the transaction so a concurrent family change cannot authorize it.
pub fn commit_in(
  db: sqlight.Connection,
  edit: Edit,
) -> Result(Configuration, String) {
  store.transaction(db, fn() {
    let candidate = edit.candidate
    use _ <- result.try(family.available_in(db, candidate.id))
    use current <- result.try(read_in(db, candidate.id))
    case
      current.revision == edit.expected.revision
      && current.family.revision == edit.expected.family_revision
    {
      False -> Error("configuration_changed")
      True -> {
        use _ <- result.try(
          store.run(
            db,
            "UPDATE transcript SET provider=? WHERE session=? AND provider IS NULL AND ?<>''",
            [
              sqlight.text(current.provider_profile),
              sqlight.text(candidate.id),
              sqlight.text(current.provider_profile),
            ],
          ),
        )
        let pinned = candidate.preferences.pinned
        use pin_order <- result.try(case pinned, current.preferences.pinned {
          False, _ -> Ok(None)
          True, True -> Ok(current.preferences.pin_order)
          True, False ->
            store.one(
              db,
              "SELECT COALESCE(MAX(pin_order),-1)+1 FROM sessions",
              [],
              decode.field(0, decode.int, decode.success),
              "pin order unavailable",
            )
            |> result.map(Some)
        })
        use _ <- result.try(
          store.run(
            db,
            "UPDATE sessions SET name=?,provider=?,model=?,protocol=?,effort=?,pinned=?,pin_order=?,archived=?,config_revision=config_revision+1 WHERE id=?",
            [
              nullable_text(candidate.name),
              sqlight.text(candidate.provider_profile),
              sqlight.text(candidate.model),
              sqlight.text(types.protocol_name(edit.protocol)),
              nullable_text(candidate.effort),
              sqlight.int(case pinned {
                True -> 1
                False -> 0
              }),
              case pin_order {
                Some(order) -> sqlight.int(order)
                None -> sqlight.null()
              },
              sqlight.int(case candidate.preferences.archived {
                True -> 1
                False -> 0
              }),
              sqlight.text(candidate.id),
            ],
          ),
        )
        use _ <- result.try(
          store.run(db, "DELETE FROM session_selection WHERE session=?", [
            sqlight.text(candidate.id),
          ]),
        )
        use _ <- result.try(
          store.run(db, "DELETE FROM session_extensions WHERE session=?", [
            sqlight.text(candidate.id),
          ]),
        )
        use _ <- result.try(
          list.try_each(edit.choices, fn(choice) {
            let enabled =
              sqlight.int(case choice.enabled {
                True -> 1
                False -> 0
              })
            case choice.kind {
              "extensions" ->
                store.run(
                  db,
                  "INSERT INTO session_extensions(session,name,enabled) VALUES(?,?,?)",
                  [
                    sqlight.text(candidate.id),
                    sqlight.text(choice.candidate),
                    enabled,
                  ],
                )
              _ ->
                store.run(
                  db,
                  "INSERT INTO session_selection(session,kind,candidate,preference_key,enabled) VALUES(?,?,?,?,?)",
                  [
                    sqlight.text(candidate.id),
                    sqlight.text(choice.kind),
                    sqlight.text(choice.candidate),
                    sqlight.text(choice.preference_key),
                    enabled,
                  ],
                )
            }
          }),
        )
        read_in(db, candidate.id)
      }
    }
  })
}

fn nullable_text(value: Option(String)) -> sqlight.Value {
  case value {
    Some(text) -> sqlight.text(text)
    None -> sqlight.null()
  }
}

pub fn initialise_in(db: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(
    store.add_columns(db, "sessions", [
      #("pinned", "INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1))"),
      #("pin_order", "INTEGER"),
      #("archived", "INTEGER NOT NULL DEFAULT 0 CHECK(archived IN (0,1))"),
      #("opens", "INTEGER NOT NULL DEFAULT 0 CHECK(opens >= 0)"),
    ]),
  )
  store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS session_visits(id TEXT PRIMARY KEY,session_id TEXT NOT NULL,opens INTEGER NOT NULL,created_at INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS session_visits_expiry ON session_visits(created_at); CREATE TABLE IF NOT EXISTS session_selection(session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,kind TEXT NOT NULL,candidate TEXT NOT NULL,preference_key TEXT NOT NULL,enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),PRIMARY KEY(session,kind,candidate)); CREATE UNIQUE INDEX IF NOT EXISTS session_selection_preference ON session_selection(session,kind,preference_key);",
  )
}

pub fn selection_in(
  db: sqlight.Connection,
  id: String,
) -> Result(Selection, String) {
  use rows <- result.try(
    store.rows(
      db,
      "SELECT kind,candidate,enabled FROM session_selection WHERE session=? UNION ALL SELECT 'extensions',name,enabled FROM session_extensions WHERE session=?",
      [sqlight.text(id), sqlight.text(id)],
      {
        use kind <- decode.field(0, decode.string)
        use name <- decode.field(1, decode.string)
        use enabled <- decode.field(2, sqlight.decode_bool())
        decode.success(#(kind, name, enabled))
      },
    ),
  )
  let choices = fn(kind) {
    rows
    |> list.filter(fn(row) { row.0 == kind })
    |> list.map(fn(row) { #(row.1, row.2) })
    |> dict.from_list
  }
  Ok(Selection(
    choices("extensions"),
    choices("skills"),
    choices("instructions"),
    choices("mcp"),
  ))
}

pub fn read_in(
  db: sqlight.Connection,
  id: String,
) -> Result(Configuration, String) {
  use family <- result.try(family.capture_in(db, id))
  use selection <- result.try(selection_in(db, id))
  store.one(
    db,
    "SELECT name,title,COALESCE(desired_workspace,cwd),COALESCE(provider,''),model,effort,config_revision,pinned,pin_order,archived,opens FROM sessions WHERE id=?",
    [sqlight.text(id)],
    {
      use name <- decode.field(0, decode.optional(decode.string))
      use automatic_name <- decode.field(1, decode.string)
      use workspace <- decode.field(2, decode.string)
      use provider <- decode.field(3, decode.string)
      use model <- decode.field(4, decode.string)
      use effort <- decode.field(5, decode.optional(decode.string))
      use revision <- decode.field(6, decode.int)
      use pinned <- decode.field(7, sqlight.decode_bool())
      use pin_order <- decode.field(8, decode.optional(decode.int))
      use archived <- decode.field(9, sqlight.decode_bool())
      use opens <- decode.field(10, decode.int)
      decode.success(Configuration(
        id,
        option.then(name, clean_name),
        clean_name(automatic_name) |> option.unwrap(""),
        workspace,
        provider,
        model,
        effort,
        revision,
        family,
        Preferences(pinned, pin_order, archived, opens),
        selection,
      ))
    },
    "session not found",
  )
}

/// A known visit returns its original count, even after subsequent visits or
/// session deletion. New identities increment and record together.
pub fn visit(
  ledger: store.Store,
  session_id: String,
  visit_id: String,
) -> Result(#(Visit, Bool), String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use known <- result.try(
        store.rows(
          db,
          "SELECT session_id,opens FROM session_visits WHERE id=?",
          [sqlight.text(visit_id)],
          {
            use session <- decode.field(0, decode.string)
            use opens <- decode.field(1, decode.int)
            decode.success(Visit(visit_id, session, opens))
          },
        ),
      )
      case known {
        [visit, ..] ->
          case visit.session_id == session_id {
            True -> Ok(#(visit, False))
            False -> Error("operation_conflict")
          }
        [] -> {
          let now = usage.now()
          use _ <- result.try(operations.validate_id(visit_id, now))
          use count <- result.try(store.one(
            db,
            "UPDATE sessions SET opens=opens+1 WHERE id=? RETURNING opens",
            [sqlight.text(session_id)],
            decode.field(0, decode.int, decode.success),
            "session not found",
          ))
          use _ <- result.try(
            store.run(
              db,
              "INSERT INTO session_visits(id,session_id,opens,created_at) VALUES(?,?,?,?)",
              [
                sqlight.text(visit_id),
                sqlight.text(session_id),
                sqlight.int(count),
                sqlight.int(now),
              ],
            ),
          )
          use _ <- result.try(
            store.run(
              db,
              "DELETE FROM session_visits WHERE id IN (SELECT id FROM session_visits WHERE created_at<? ORDER BY created_at LIMIT 128)",
              [sqlight.int(now - operations.retention_ms)],
            ),
          )
          Ok(#(Visit(visit_id, session_id, count), True))
        }
      }
    })
  })
}
