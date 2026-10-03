//// Bounded durable session selection. A page's membership, metadata and
//// family validator are read on one store connection turn; live fields are
//// supplied separately by already running actors.

import albedo/daemon/conversation
import albedo/daemon/family
import albedo/daemon/store
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Filter {
  Filter(
    roots: Bool,
    parent: Option(String),
    family: Option(String),
    workspace: Option(String),
    search: Option(String),
    archived: Option(Bool),
    frequent: Bool,
    include_ids: Option(List(String)),
    exclude_ids: List(String),
  )
}

pub type Key {
  Key(opens: Int, activity: Int, id: String)
}

pub type Page {
  Page(
    items: List(conversation.CapturedInfo),
    next: Option(Key),
    family: Option(family.Facts),
  )
}

fn value_clause(
  value: Option(a),
  predicate: String,
  encode: fn(a) -> sqlight.Value,
) -> #(String, List(sqlight.Value)) {
  case value {
    None -> #("", [])
    Some(value) -> #(" AND " <> predicate, [encode(value)])
  }
}

pub fn page(
  ledger: store.Store,
  filter: Filter,
  after: Option(Key),
  limit: Int,
) -> Result(Page, String) {
  store.query(ledger, fn(db) {
    use group <- result.try(case filter.family {
      None -> Ok(None)
      Some(id) -> {
        use _ <- result.try(conversation.read_info(db, id))
        family.capture_in(db, id) |> result.map(Some)
      }
    })
    use _ <- result.try(case filter.parent {
      None -> Ok(Nil)
      Some(id) -> conversation.read_info(db, id) |> result.replace(Nil)
    })
    let group_clause = case group {
      None -> #("", [])
      Some(group) -> #(
        " AND s.id IN (WITH RECURSIVE members(id) AS (SELECT ? UNION SELECT f.session FROM session_family f JOIN members m ON f.parent=m.id) SELECT id FROM members)",
        [sqlight.text(group.root_id)],
      )
    }
    let roots_clause = case filter.roots {
      True -> #(" AND f.session IS NULL", [])
      False -> #("", [])
    }
    let search = case filter.search {
      None -> #("", [])
      Some(text) -> #(
        " AND (instr(lower(COALESCE(s.name,f.name,s.title)),lower(?))>0 OR instr(lower(s.id),lower(?))=1)",
        [sqlight.text(text), sqlight.text(text)],
      )
    }
    let ids = fn(values) {
      sqlight.text(json.to_string(json.array(values, json.string)))
    }
    let include =
      value_clause(
        filter.include_ids,
        "s.id IN (SELECT value FROM json_each(?))",
        ids,
      )
    let exclude = case filter.exclude_ids {
      [] -> #("", [])
      values -> #(" AND s.id NOT IN (SELECT value FROM json_each(?))", [
        ids(values),
      ])
    }
    let activity = "COALESCE(s.activity_at,0)"
    let cursor = case after {
      None -> #("", [])
      Some(key) ->
        case filter.frequent {
          False -> #(
            " AND (" <> activity <> "<? OR (" <> activity <> "=? AND s.id>?))",
            [
              sqlight.int(key.activity),
              sqlight.int(key.activity),
              sqlight.text(key.id),
            ],
          )
          True -> #(
            " AND (s.opens<? OR (s.opens=? AND ("
              <> activity
              <> "<? OR ("
              <> activity
              <> "=? AND s.id>?))))",
            [
              sqlight.int(key.opens),
              sqlight.int(key.opens),
              sqlight.int(key.activity),
              sqlight.int(key.activity),
              sqlight.text(key.id),
            ],
          )
        }
    }
    let clauses = [
      roots_clause,
      group_clause,
      value_clause(filter.parent, "f.parent=?", sqlight.text),
      value_clause(filter.workspace, "s.cwd=?", sqlight.text),
      search,
      value_clause(filter.archived, "s.archived=?", fn(value) {
        sqlight.int(case value {
          True -> 1
          False -> 0
        })
      }),
      include,
      exclude,
      cursor,
    ]
    let where = string.join(list.map(clauses, fn(clause) { clause.0 }), "")
    let arguments = list.flat_map(clauses, fn(clause) { clause.1 })
    let limit = int.clamp(limit, 1, 200)
    let order =
      case filter.frequent {
        True -> "s.opens DESC,"
        False -> ""
      }
      <> activity
      <> " DESC,s.id ASC"
    use rows <- result.try(
      store.rows(
        db,
        "SELECT s.id,s.opens,"
          <> activity
          <> " FROM sessions s LEFT JOIN session_family f ON f.session=s.id WHERE 1=1"
          <> where
          <> " ORDER BY "
          <> order
          <> " LIMIT ?",
        list.append(arguments, [sqlight.int(limit + 1)]),
        {
          use id <- decode.field(0, decode.string)
          use opens <- decode.field(1, decode.int)
          use activity <- decode.field(2, decode.int)
          decode.success(Key(opens, activity, id))
        },
      ),
    )
    let shown = list.take(rows, limit)
    use items <- result.try(
      list.try_map(shown, fn(key) { conversation.capture_in(db, key.id) }),
    )
    Ok(Page(
      items,
      case list.length(rows) > limit {
        False -> None
        True -> list.last(shown) |> option.from_result
      },
      group,
    ))
  })
}
