//// Which session spawned which. A root session has no row; a child's row names
//// its parent, the name its siblings and parent address it by, and its depth.
//// Names resolve only inside a family: anything further away is addressed by
//// session id, so a title shared by two unrelated sessions cannot misdirect.

import albedo/daemon/store
import albedo/daemon/usage
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Member {
  Member(
    session: String,
    parent: String,
    name: String,
    depth: Int,
    closed: Bool,
  )
}

/// Children of children of children, and no further. Any agent can mail any
/// session by id, so depth is never needed just to reach someone.
pub const max_depth = 3

/// Open children one parent may have at once.
pub const max_children = 8

const schema = "
CREATE TABLE IF NOT EXISTS session_family (
 session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
 parent TEXT NOT NULL REFERENCES sessions(id),
 name TEXT NOT NULL,
 depth INTEGER NOT NULL CHECK(depth >= 1),
 created_at INTEGER NOT NULL,
 closed_at INTEGER,
 UNIQUE(parent,name)
);
CREATE INDEX IF NOT EXISTS session_family_parent ON session_family(parent);
"

pub fn initialise(db: store.Store) -> Result(Nil, String) {
  store.query(db, fn(connection) {
    sqlight.exec(schema, connection) |> result.map_error(fn(e) { e.message })
  })
}

const columns = "session,parent,name,depth,closed_at IS NOT NULL"

fn decoder() {
  use session <- decode.field(0, decode.string)
  use parent <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use depth <- decode.field(3, decode.int)
  use closed <- decode.field(4, sqlight.decode_bool())
  decode.success(Member(session, parent, name, depth, closed))
}

fn rows(connection, sql, args) -> Result(List(Member), String) {
  sqlight.query(sql, connection, args, decoder())
  |> result.map_error(fn(e) { e.message })
}

/// A name siblings can say: short, lowercase, and not a reserved address.
pub fn valid_name(name: String) -> Result(Nil, String) {
  let allowed = string.to_graphemes("abcdefghijklmnopqrstuvwxyz0123456789-_")
  case
    name != ""
    && string.length(name) <= 32
    && list.all(string.to_graphemes(name), list.contains(allowed, _))
  {
    False -> Error("name must be 1-32 characters of a-z, 0-9, '-' or '_'")
    True ->
      case name {
        "parent" | "self" | "all" -> Error("'" <> name <> "' is reserved")
        _ -> Ok(Nil)
      }
  }
}

pub fn get(db: store.Store, session: String) -> Result(Option(Member), String) {
  store.query(db, fn(connection) {
    rows(
      connection,
      "SELECT " <> columns <> " FROM session_family WHERE session=?",
      [sqlight.text(session)],
    )
  })
  |> result.map(fn(found) { list.first(found) |> option.from_result })
}

pub fn children(
  db: store.Store,
  parent: String,
) -> Result(List(Member), String) {
  store.query(db, fn(connection) {
    rows(
      connection,
      "SELECT "
        <> columns
        <> " FROM session_family WHERE parent=? ORDER BY created_at",
      [sqlight.text(parent)],
    )
  })
}

/// Record `child` as `parent`'s child named `name`. The child's session row
/// must already exist; the caller creates it in the same breath.
pub fn link(
  db: store.Store,
  child: String,
  parent: String,
  name: String,
) -> Result(Member, String) {
  use _ <- result.try(valid_name(name))
  store.query(db, fn(connection) {
    use above <- result.try(
      rows(
        connection,
        "SELECT " <> columns <> " FROM session_family WHERE session=?",
        [sqlight.text(parent)],
      ),
    )
    let depth = case above {
      [member] -> member.depth + 1
      _ -> 1
    }
    use siblings <- result.try(
      rows(
        connection,
        "SELECT " <> columns <> " FROM session_family WHERE parent=?",
        [sqlight.text(parent)],
      ),
    )
    let open = list.filter(siblings, fn(member) { !member.closed })
    use _ <- result.try(
      case
        depth > max_depth,
        list.length(open) >= max_children,
        list.any(siblings, fn(member) { member.name == name })
      {
        True, _, _ ->
          Error(
            "agents nest at most "
            <> int.to_string(max_depth)
            <> " deep; mail a session by id instead of nesting to reach it",
          )
        _, True, _ ->
          Error(
            "at most "
            <> int.to_string(max_children)
            <> " open children; close one you are done with first",
          )
        _, _, True -> Error("a child named '" <> name <> "' already exists")
        False, False, False -> Ok(Nil)
      },
    )
    sqlight.query(
      "INSERT INTO session_family(session,parent,name,depth,created_at) VALUES(?,?,?,?,?)",
      connection,
      [
        sqlight.text(child),
        sqlight.text(parent),
        sqlight.text(name),
        sqlight.int(depth),
        sqlight.int(usage.now()),
      ],
      decode.dynamic,
    )
    |> result.map_error(fn(e) { e.message })
    |> result.replace(Member(child, parent, name, depth, False))
  })
}

pub fn close(db: store.Store, session: String) -> Result(Nil, String) {
  store.query(db, fn(connection) {
    sqlight.query(
      "UPDATE session_family SET closed_at=COALESCE(closed_at,?) WHERE session=?",
      connection,
      [sqlight.int(usage.now()), sqlight.text(session)],
      decode.dynamic,
    )
    |> result.replace(Nil)
    |> result.map_error(fn(e) { e.message })
  })
}

pub type Address {
  Address(session: String, name: String)
}

/// Who `to` means when `caller` says it: "parent", a session id, or the name
/// of a child, a sibling, or the parent, searched in that order.
pub fn resolve(
  db: store.Store,
  caller: String,
  to: String,
) -> Result(Address, String) {
  store.query(db, fn(connection) {
    use me <- result.try(
      rows(
        connection,
        "SELECT " <> columns <> " FROM session_family WHERE session=?",
        [sqlight.text(caller)],
      ),
    )
    let parent = case me {
      [member] -> Some(member.parent)
      _ -> None
    }
    use by_id <- result.try(
      sqlight.query(
        "SELECT s.id,COALESCE(f.name,s.title) FROM sessions s LEFT JOIN session_family f ON f.session=s.id WHERE s.id=?",
        connection,
        [sqlight.text(to)],
        {
          use id <- decode.field(0, decode.string)
          use name <- decode.field(1, decode.string)
          decode.success(Address(id, name))
        },
      )
      |> result.map_error(fn(e) { e.message }),
    )
    case to, parent, by_id {
      "parent", None, _ -> Error("this session has no parent; it is a root")
      "parent", Some(id), _ -> Ok(Address(id, parent_name(connection, id)))
      _, _, [address] -> Ok(address)
      _, _, _ -> {
        use children <- result.try(
          rows(
            connection,
            "SELECT "
              <> columns
              <> " FROM session_family WHERE parent=? AND name=?",
            [sqlight.text(caller), sqlight.text(to)],
          ),
        )
        use siblings <- result.try(case parent {
          None -> Ok([])
          Some(id) ->
            rows(
              connection,
              "SELECT "
                <> columns
                <> " FROM session_family WHERE parent=? AND name=? AND session<>?",
              [sqlight.text(id), sqlight.text(to), sqlight.text(caller)],
            )
        })
        let up = case parent {
          Some(id) ->
            case parent_name(connection, id) == to {
              True -> [Address(id, to)]
              False -> []
            }
          None -> []
        }
        case
          list.map(list.append(children, siblings), fn(member) {
            Address(member.session, member.name)
          })
          |> list.append(up)
        {
          [address, ..] -> Ok(address)
          [] ->
            Error(
              "no agent named '"
              <> to
              <> "' among your children, siblings, or parent; mail sessions outside your family by id",
            )
        }
      }
    }
  })
}

/// How other agents address `session`: its family name, or its title when it
/// is a root.
pub fn name_of(db: store.Store, session: String) -> String {
  store.query(db, fn(connection) { parent_name(connection, session) })
}

/// A parent's name as its children say it: its own family name, or its title
/// when it is a root.
fn parent_name(connection, id: String) -> String {
  sqlight.query(
    "SELECT COALESCE(f.name,s.title) FROM sessions s LEFT JOIN session_family f ON f.session=s.id WHERE s.id=?",
    connection,
    [sqlight.text(id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(found) { list.first(found) |> result.unwrap("parent") })
  |> result.unwrap("parent")
}
