//// Workspaces linked into one project: the same work in several places, such
//// as one repository checked out on two hosts. Each workspace keeps its own
//// memory and work items, written where it is; reads cover the whole group,
//// so nothing is ever merged and unlinking loses nothing. A member whose
//// folder is gone stays until someone removes it. robot-docs/workspaces.md
//// has the rules.

import albedo/daemon/store
import gleam/dynamic/decode
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
