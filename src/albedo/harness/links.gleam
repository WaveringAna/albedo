//// Workspaces linked into one project: the same work in several places, such
//// as one repository checked out on two hosts. Each workspace keeps its own
//// memory and work items, written where it is; reads cover the whole group,
//// so nothing is ever merged and unlinking loses nothing. A member whose
//// folder is gone stays until someone removes it. robot-docs/workspaces.md
//// has the rules.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/list
import gleam/result
import sqlight

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS workspace_links (
      workspace TEXT PRIMARY KEY, grp INTEGER NOT NULL,
      linked_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
    CREATE INDEX IF NOT EXISTS workspace_links_grp ON workspace_links(grp);",
  )
}

/// The workspace and every workspace linked with it, the workspace first and
/// the rest in the order they joined. Alone, or with no links table (an
/// embedded runtime), it is just itself.
pub fn members(db: sqlight.Connection, workspace: String) -> List(String) {
  let linked =
    store.rows(
      db,
      "SELECT workspace FROM workspace_links WHERE workspace<>?1 AND grp=(SELECT grp FROM workspace_links WHERE workspace=?1) ORDER BY linked_at, workspace",
      [sqlight.text(workspace)],
      decode.field(0, decode.string, decode.success),
    )
  [workspace, ..result.unwrap(linked, [])]
}

pub fn group(storage: store.Store, workspace: String) -> List(String) {
  store.query(storage, members(_, workspace))
}

/// Link two workspaces, and so their groups: everything `other` was linked
/// with joins `workspace`'s group.
pub fn link(
  storage: store.Store,
  workspace: String,
  other: String,
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(apply(db))
      use groups <- result.try(store.rows(
        db,
        "SELECT grp FROM workspace_links WHERE workspace IN (?,?) ORDER BY workspace=? DESC",
        [sqlight.text(workspace), sqlight.text(other), sqlight.text(workspace)],
        decode.field(0, decode.int, decode.success),
      ))
      use target <- result.try(case groups {
        [first, ..] -> Ok(first)
        [] ->
          store.rows(
            db,
            "SELECT coalesce(max(grp),0)+1 FROM workspace_links",
            [],
            decode.field(0, decode.int, decode.success),
          )
          |> result.map(fn(next) { list.first(next) |> result.unwrap(1) })
      })
      use _ <- result.try(
        list.try_each(list.drop(groups, 1), fn(old) {
          store.run(db, "UPDATE workspace_links SET grp=? WHERE grp=?", [
            sqlight.int(target),
            sqlight.int(old),
          ])
        }),
      )
      list.try_each([workspace, other], fn(member) {
        store.run(
          db,
          "INSERT INTO workspace_links(workspace,grp) VALUES(?,?) ON CONFLICT(workspace) DO NOTHING",
          [sqlight.text(member), sqlight.int(target)],
        )
      })
    })
  })
}

/// Take one workspace out of its group. Its memory and work items stay
/// where they are; linking it again brings them back. A group left with one
/// member is no group.
pub fn unlink(storage: store.Store, workspace: String) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(apply(db))
      use _ <- result.try(
        store.run(db, "DELETE FROM workspace_links WHERE workspace=?", [
          sqlight.text(workspace),
        ]),
      )
      store.run(
        db,
        "DELETE FROM workspace_links WHERE grp IN (SELECT grp FROM workspace_links GROUP BY grp HAVING count(*)<2)",
        [],
      )
    })
  })
}
