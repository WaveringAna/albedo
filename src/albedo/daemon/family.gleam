//// Which session spawned which. A root session has no row; a child's row names
//// its parent, the name its siblings and parent address it by, and its depth.
//// Names resolve only inside a family: anything further away is addressed by
//// session id, so a title shared by two unrelated sessions cannot misdirect.

import albedo/clock

import albedo/daemon/operations
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

pub type Facts {
  Facts(root_id: String, member: Option(Member), revision: Int)
}

/// Family identity and its membership validator share the caller's store read.
pub fn capture_in(
  connection: sqlight.Connection,
  session: String,
) -> Result(Facts, String) {
  use root <- result.try(root_in(connection, session))
  use revision <- result.try(store.one(
    connection,
    "SELECT family_revision FROM sessions WHERE id=?",
    [sqlight.text(root)],
    decode.field(0, decode.int, decode.success),
    "family root not found",
  ))
  use member <- result.try(
    rows(connection, members("WHERE session=?"), [sqlight.text(session)]),
  )
  Ok(Facts(root, list.first(member) |> option.from_result, revision))
}

fn root_in(
  connection: sqlight.Connection,
  session: String,
) -> Result(String, String) {
  store.one(
    connection,
    "WITH RECURSIVE lineage(id,depth) AS (SELECT ?,0 UNION ALL SELECT f.parent,l.depth+1 FROM session_family f JOIN lineage l ON f.session=l.id WHERE l.depth<?) SELECT id FROM lineage ORDER BY depth DESC LIMIT 1",
    [sqlight.text(session), sqlight.int(max_depth)],
    decode.field(0, decode.string, decode.success),
    "family root not found",
  )
}

/// Called before removing members, while their ancestor links still exist.
pub fn changed_in(
  connection: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use root <- result.try(root_in(connection, session))
  store.run(
    connection,
    "UPDATE sessions SET family_revision=family_revision+1 WHERE id=?",
    [sqlight.text(root)],
  )
}

/// Children of children of children, and no further. Any agent can mail any
/// session by id, so depth is never needed just to reach someone.
pub const max_depth = 3

/// Open children one parent may have at once.
const max_children = 12

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
  store.query(db, fn(connection) { store.exec(connection, schema) })
}

const columns = "session,parent,name,depth,closed_at IS NOT NULL"

/// Every member query: the shared column list, with the given filter.
fn members(filter: String) -> String {
  "SELECT " <> columns <> " FROM session_family " <> filter
}

fn decoder() -> decode.Decoder(Member) {
  use session <- decode.field(0, decode.string)
  use parent <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use depth <- decode.field(3, decode.int)
  use closed <- decode.field(4, sqlight.decode_bool())
  decode.success(Member(session, parent, name, depth, closed))
}

fn rows(
  connection: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
) -> Result(List(Member), String) {
  store.rows(connection, sql, args, decoder())
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
  store.read(db, members("WHERE session=?"), [sqlight.text(session)], decoder())
  |> result.map(fn(found) { list.first(found) |> option.from_result })
}

/// Every session that has a parent. Session lists leave these out: a child is
/// reached through its parent's agents view.
pub fn descendants(db: store.Store) -> Result(List(String), String) {
  store.read(
    db,
    "SELECT session FROM session_family",
    [],
    decode.field(0, decode.string, decode.success),
  )
}

pub fn children(
  db: store.Store,
  parent: String,
) -> Result(List(Member), String) {
  store.read(
    db,
    members("WHERE parent=? ORDER BY created_at"),
    [sqlight.text(parent)],
    decoder(),
  )
}

/// The caller owns the transaction that also creates the child and its task.
pub fn link_in(
  connection: sqlight.Connection,
  child: String,
  parent: String,
  name: String,
) -> Result(Member, String) {
  use _ <- result.try(available_in(connection, parent))
  use _ <- result.try(valid_name(name))
  use above <- result.try(
    rows(connection, members("WHERE session=?"), [sqlight.text(parent)]),
  )
  let depth = case above {
    [member] -> member.depth + 1
    _ -> 1
  }
  use siblings <- result.try(
    rows(connection, members("WHERE parent=?"), [sqlight.text(parent)]),
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
  use _ <- result.try(
    store.run(
      connection,
      "INSERT INTO session_family(session,parent,name,depth,created_at) VALUES(?,?,?,?,?)",
      [
        sqlight.text(child),
        sqlight.text(parent),
        sqlight.text(name),
        sqlight.int(depth),
        sqlight.int(usage.now()),
      ],
    ),
  )
  changed_in(connection, parent)
  |> result.replace(Member(child, parent, name, depth, False))
}

pub fn close(db: store.Store, session: String) -> Result(Nil, String) {
  store.query(db, fn(connection) {
    store.transaction(connection, fn() {
      use found <- result.try(
        rows(connection, members("WHERE session=?"), [sqlight.text(session)]),
      )
      case found {
        [Member(closed: False, ..)] -> {
          use _ <- result.try(
            store.run(
              connection,
              "UPDATE session_family SET closed_at=? WHERE session=?",
              [sqlight.int(usage.now()), sqlight.text(session)],
            ),
          )
          changed_in(connection, session)
        }
        _ -> Ok(Nil)
      }
    })
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
      rows(connection, members("WHERE session=?"), [sqlight.text(caller)]),
    )
    let parent = case me {
      [member] -> Some(member.parent)
      _ -> None
    }
    use by_id <- result.try(
      store.rows(
        connection,
        "SELECT s.id,COALESCE(f.name,NULLIF(s.name,''),s.title) FROM sessions s LEFT JOIN session_family f ON f.session=s.id WHERE s.id=?",
        [sqlight.text(to)],
        {
          use id <- decode.field(0, decode.string)
          use name <- decode.field(1, decode.string)
          decode.success(Address(id, name))
        },
      ),
    )
    case to, parent, by_id {
      "parent", None, _ -> Error("this session has no parent; it is a root")
      "parent", Some(id), _ -> Ok(Address(id, parent_name(connection, id)))
      _, _, [address] -> Ok(address)
      _, _, _ -> {
        use children <- result.try(
          rows(connection, members("WHERE parent=? AND name=?"), [
            sqlight.text(caller),
            sqlight.text(to),
          ]),
        )
        use siblings <- result.try(case parent {
          None -> Ok([])
          Some(id) ->
            rows(
              connection,
              members("WHERE parent=? AND name=? AND session<>?"),
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

/// How other agents address `session`: its family name, or when it is a root
/// the name it was given or its title.
pub fn name_of(db: store.Store, session: String) -> String {
  store.query(db, fn(connection) { parent_name(connection, session) })
}

/// A parent's name as its children say it: its own family name, or when it
/// is a root the name it was given or its title.
fn parent_name(connection: sqlight.Connection, id: String) -> String {
  store.rows(
    connection,
    "SELECT COALESCE(f.name,NULLIF(s.name,''),s.title) FROM sessions s LEFT JOIN session_family f ON f.session=s.id WHERE s.id=?",
    [sqlight.text(id)],
    decode.field(0, decode.string, decode.success),
  )
  |> result.map(fn(found) { list.first(found) |> result.unwrap("parent") })
  |> result.unwrap("parent")
}

/// A deletion claim blocks child and execution admission for its captured rows.
pub type DeletionRequest {
  DeletionRequest(
    session: String,
    configuration_revision: Int,
    family_revision: Int,
    subtree: Bool,
  )
}

pub type DeletionClaim {
  DeletionClaim(token: String, session: String, captured_count: Int)
}

pub type DeletionMember {
  DeletionMember(id: String, depth: Int)
}

pub fn available_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use available <- result.try(store.one(
    db,
    "SELECT deletion_id IS NULL FROM sessions WHERE id=?",
    [sqlight.text(session)],
    decode.field(0, decode.int, decode.success),
    "session not found",
  ))
  case available {
    1 -> Ok(Nil)
    _ -> Error("deletion_in_progress")
  }
}

const deletion_membership = "WITH RECURSIVE captured(id) AS (SELECT ? UNION SELECT f.session FROM session_family f JOIN captured c ON f.parent=c.id WHERE ?=1) "

pub fn claim_deletion(
  ledger: store.Store,
  request: DeletionRequest,
  token: String,
  deadline: Int,
) -> Result(DeletionClaim, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(case clock.monotonic_ms() >= deadline {
        True -> Error("deletion admission deadline reached")
        False -> Ok(Nil)
      })
      use revision <- result.try(store.one(
        db,
        "SELECT config_revision FROM sessions WHERE id=?",
        [sqlight.text(request.session)],
        decode.field(0, decode.int, decode.success),
        "session not found",
      ))
      use facts <- result.try(capture_in(db, request.session))
      use _ <- result.try(
        case
          revision == request.configuration_revision
          && facts.revision == request.family_revision
        {
          True -> Ok(Nil)
          False -> Error("configuration_changed")
        },
      )
      let scope = case request.subtree {
        True -> 1
        False -> 0
      }
      use leaf_children <- result.try(store.one(
        db,
        "SELECT COUNT(*) FROM session_family WHERE parent=?",
        [sqlight.text(request.session)],
        decode.field(0, decode.int, decode.success),
        "family unavailable",
      ))
      use _ <- result.try(case !request.subtree && leaf_children > 0 {
        True -> Error("session_has_children")
        False -> Ok(Nil)
      })
      use active <- result.try(store.one(
        db,
        "SELECT EXISTS(SELECT 1 FROM input_turns WHERE session=? AND state='running')",
        [sqlight.text(request.session)],
        decode.field(0, decode.int, decode.success),
        "session activity unavailable",
      ))
      use _ <- result.try(case !request.subtree && active == 1 {
        True -> Error("session must be idle to delete")
        False -> Ok(Nil)
      })
      use counts <- result.try(store.one(
        db,
        deletion_membership
          <> "SELECT COUNT(*),COALESCE(SUM(deletion_id IS NOT NULL),0) FROM sessions WHERE id IN (SELECT id FROM captured)",
        [sqlight.text(request.session), sqlight.int(scope)],
        {
          use count <- decode.field(0, decode.int)
          use locked <- decode.field(1, decode.int)
          decode.success(#(count, locked))
        },
        "family unavailable",
      ))
      use _ <- result.try(case counts.1 {
        0 -> Ok(Nil)
        _ -> Error("deletion_in_progress")
      })
      use _ <- result.try(
        store.run(
          db,
          deletion_membership
            <> "UPDATE sessions SET deletion_id=? WHERE id IN (SELECT id FROM captured)",
          [
            sqlight.text(request.session),
            sqlight.int(scope),
            sqlight.text(token),
          ],
        ),
      )
      use _ <- result.try(operations.cancel_deletion_in(db, token))
      Ok(DeletionClaim(token, request.session, counts.0))
    })
  })
}

/// Keyset pages retain deepest-first order even as earlier rows disappear.
pub fn deletion_members(
  ledger: store.Store,
  claim: DeletionClaim,
  after_member: Option(DeletionMember),
) -> Result(List(DeletionMember), String) {
  let depth = option.map(after_member, fn(member) { member.depth })
  let id = option.map(after_member, fn(member) { member.id })
  store.read(
    ledger,
    "SELECT s.id,COALESCE(f.depth,0) FROM sessions s LEFT JOIN session_family f ON f.session=s.id WHERE s.deletion_id=? AND (? IS NULL OR COALESCE(f.depth,0)<? OR (COALESCE(f.depth,0)=? AND s.id>?)) ORDER BY COALESCE(f.depth,0) DESC,s.id LIMIT 200",
    [
      sqlight.text(claim.token),
      sqlight.nullable(sqlight.int, depth),
      sqlight.nullable(sqlight.int, depth),
      sqlight.nullable(sqlight.int, depth),
      sqlight.nullable(sqlight.text, id),
    ],
    {
      use id <- decode.field(0, decode.string)
      use depth <- decode.field(1, decode.int)
      decode.success(DeletionMember(id, depth))
    },
  )
}

pub fn release_deletion(
  ledger: store.Store,
  claim: DeletionClaim,
) -> Result(Nil, String) {
  store.write(
    ledger,
    "UPDATE sessions SET deletion_id=NULL WHERE deletion_id=?",
    [sqlight.text(claim.token)],
  )
}
