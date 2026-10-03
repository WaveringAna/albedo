//// Membership captures and conditional commits share the daemon's durable owner.
//// Triggers also observe membership writes made by the native model interface.

import albedo/daemon/http_api as api
import albedo/daemon/store
import albedo/harness/links
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import sqlight

pub type Group {
  Group(
    workspace: String,
    members: List(String),
    revision: Int,
    total: Int,
    id: String,
  )
}

pub fn initialise(storage: store.Store) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    use _ <- result.try(links.apply(db))
    store.exec(
      db,
      "CREATE TABLE IF NOT EXISTS link_revision_clock (id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL); INSERT OR IGNORE INTO link_revision_clock VALUES(1,1); CREATE TABLE IF NOT EXISTS link_revisions (workspace TEXT PRIMARY KEY, revision INTEGER NOT NULL);
CREATE TRIGGER IF NOT EXISTS link_revision_insert AFTER INSERT ON workspace_links BEGIN UPDATE link_revision_clock SET value=value+1 WHERE id=1; INSERT OR REPLACE INTO link_revisions SELECT workspace,(SELECT value FROM link_revision_clock WHERE id=1) FROM workspace_links WHERE grp=NEW.grp; END;
CREATE TRIGGER IF NOT EXISTS link_revision_update AFTER UPDATE OF grp ON workspace_links BEGIN UPDATE link_revision_clock SET value=value+1 WHERE id=1; INSERT OR REPLACE INTO link_revisions SELECT workspace,(SELECT value FROM link_revision_clock WHERE id=1) FROM workspace_links WHERE grp IN (OLD.grp,NEW.grp); END;
CREATE TRIGGER IF NOT EXISTS link_revision_delete AFTER DELETE ON workspace_links BEGIN UPDATE link_revision_clock SET value=value+1 WHERE id=1; INSERT OR REPLACE INTO link_revisions SELECT workspace,(SELECT value FROM link_revision_clock WHERE id=1) FROM workspace_links WHERE grp=OLD.grp; INSERT OR REPLACE INTO link_revisions VALUES(OLD.workspace,(SELECT value FROM link_revision_clock WHERE id=1)); END;",
    )
  })
}

fn metadata(
  db: sqlight.Connection,
  workspace: String,
) -> Result(Group, String) {
  use revision <- result.try(store.one(
    db,
    "SELECT coalesce((SELECT revision FROM link_revisions WHERE workspace=?),1)",
    [sqlight.text(workspace)],
    decode.field(0, decode.int, decode.success),
    "links revision missing",
  ))
  use groups <- result.try(store.rows(
    db,
    "SELECT grp FROM workspace_links WHERE workspace=?",
    [sqlight.text(workspace)],
    decode.field(0, decode.int, decode.success),
  ))
  use total <- result.try(store.one(
    db,
    "SELECT max(1,(SELECT count(*) FROM workspace_links WHERE grp=(SELECT grp FROM workspace_links WHERE workspace=?)))",
    [sqlight.text(workspace)],
    decode.field(0, decode.int, decode.success),
    "links count missing",
  ))
  let id = case groups {
    [group, ..] -> "group-" <> int.to_string(group)
    [] -> "singleton-" <> { api.etag(workspace) |> string.replace("\"", "") }
  }
  Ok(Group(workspace, [], revision, total, id))
}

fn capture(db: sqlight.Connection, workspace: String) -> Result(Group, String) {
  use group <- result.try(metadata(db, workspace))
  use linked <- result.try(store.rows(
    db,
    "SELECT workspace FROM workspace_links WHERE workspace<>?1 AND grp=(SELECT grp FROM workspace_links WHERE workspace=?1) ORDER BY linked_at,workspace",
    [sqlight.text(workspace)],
    decode.field(0, decode.string, decode.success),
  ))
  Ok(Group(..group, members: [workspace, ..linked]))
}

pub fn read(storage: store.Store, workspace: String) -> Result(Group, String) {
  store.query(storage, metadata(_, workspace))
}

/// Read only the requested bounded page in the same owner call as its metadata.
pub fn page(
  storage: store.Store,
  workspace: String,
  revision: Int,
  offset: Int,
  limit: Int,
) -> Result(Group, String) {
  store.query(storage, fn(db) {
    use group <- result.try(metadata(db, workspace))
    use _ <- result.try(case group.revision == revision && offset >= 0 {
      True -> Ok(Nil)
      False -> Error("links page changed")
    })
    use members <- result.try(case group.total {
      1 -> Ok(list.drop([workspace], offset) |> list.take(limit))
      _ ->
        store.rows(
          db,
          "SELECT workspace FROM workspace_links WHERE grp=(SELECT grp FROM workspace_links WHERE workspace=?1) ORDER BY workspace=?1 DESC,linked_at,workspace LIMIT ?2 OFFSET ?3",
          [sqlight.text(workspace), sqlight.int(limit), sqlight.int(offset)],
          decode.field(0, decode.string, decode.success),
        )
    })
    Ok(Group(..group, members: members))
  })
}

pub fn etag(group: Group) -> String {
  let workspace = api.etag(group.workspace) |> string.replace("\"", "")
  "\"links-" <> workspace <> "-" <> int.to_string(group.revision) <> "\""
}

pub fn merge(
  storage: store.Store,
  workspace: String,
  observed: String,
  other: String,
  other_observed: String,
) -> Result(#(Group, Group, Group), String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use own <- result.try(capture(db, workspace))
      use theirs <- result.try(capture(db, other))
      use _ <- result.try(
        case etag(own) == observed && etag(theirs) == other_observed {
          True -> Ok(Nil)
          False -> Error("links changed")
        },
      )
      use _ <- result.try(
        case workspace == other || list.contains(own.members, other) {
          True -> Error("already linked")
          False -> Ok(Nil)
        },
      )
      use groups <- result.try(store.rows(
        db,
        "SELECT grp FROM workspace_links WHERE workspace IN (?,?) ORDER BY workspace=? DESC",
        [sqlight.text(workspace), sqlight.text(other), sqlight.text(workspace)],
        decode.field(0, decode.int, decode.success),
      ))
      use target <- result.try(case groups {
        [first, ..] -> Ok(first)
        [] ->
          store.one(
            db,
            "SELECT coalesce(max(grp),0)+1 FROM workspace_links",
            [],
            decode.field(0, decode.int, decode.success),
            "links group missing",
          )
      })
      use _ <- result.try(
        list.try_each(list.drop(groups, 1), fn(old) {
          store.run(db, "UPDATE workspace_links SET grp=? WHERE grp=?", [
            sqlight.int(target),
            sqlight.int(old),
          ])
        }),
      )
      use _ <- result.try(
        list.try_each([workspace, other], fn(member) {
          store.run(
            db,
            "INSERT INTO workspace_links(workspace,grp) VALUES(?,?) ON CONFLICT(workspace) DO NOTHING",
            [sqlight.text(member), sqlight.int(target)],
          )
        }),
      )
      use changed <- result.try(capture(db, workspace))
      Ok(#(own, theirs, changed))
    })
  })
}

pub fn unlink(
  storage: store.Store,
  workspace: String,
  observed: String,
  member: String,
) -> Result(#(Group, Group), String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use own <- result.try(capture(db, workspace))
      use _ <- result.try(case etag(own) == observed {
        True -> Ok(Nil)
        False -> Error("links changed")
      })
      use _ <- result.try(
        case
          list.length(own.members) > 1 && list.contains(own.members, member)
        {
          True -> Ok(Nil)
          False -> Error("member not linked")
        },
      )
      use _ <- result.try(
        store.run(db, "DELETE FROM workspace_links WHERE workspace=?", [
          sqlight.text(member),
        ]),
      )
      use _ <- result.try(
        store.run(
          db,
          "DELETE FROM workspace_links WHERE grp IN (SELECT grp FROM workspace_links GROUP BY grp HAVING count(*)<2)",
          [],
        ),
      )
      use changed <- result.try(capture(db, workspace))
      Ok(#(own, changed))
    })
  })
}

pub fn group_id(group: Group) -> String {
  group.id
}
