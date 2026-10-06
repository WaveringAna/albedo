//// Durable workspace intent. A family move records destinations before any
//// kernel cleanup; each session acknowledges only the revision it applied.

import albedo/daemon/family
import albedo/daemon/session_configuration
import albedo/daemon/store
import albedo/harness/location
import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/result
import sqlight

pub type Pending {
  Pending(active: String, desired: String, revision: Int)
}

pub type Request {
  Request(
    session: String,
    expected: session_configuration.Version,
    destination: String,
  )
}

pub type ChangeFailure {
  Destination(location.Failure)
  Native(String)
}

pub type Recorded {
  Recorded(
    move_id: String,
    previous: String,
    destination: String,
    affected_count: Int,
    session_ids: List(String),
    truncated: Bool,
  )
}

pub type Report {
  Report(
    applied_count: Int,
    deferred_count: Int,
    applied_ids: List(String),
    deferred_ids: List(String),
    truncated: Bool,
    superseded_count: Int,
  )
}

pub fn initialise_in(db: sqlight.Connection) -> Result(Nil, String) {
  store.add_columns(db, "sessions", [
    #("desired_workspace", "TEXT"),
    #("workspace_revision", "INTEGER NOT NULL DEFAULT 0"),
    #("workspace_move_id", "TEXT"),
  ])
}

pub fn pending_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Option(Pending), String) {
  use rows <- result.try(
    store.rows(
      db,
      "SELECT cwd,desired_workspace,workspace_revision FROM sessions WHERE id=? AND desired_workspace IS NOT NULL",
      [sqlight.text(session)],
      {
        use active <- decode.field(0, decode.string)
        use desired <- decode.field(1, decode.string)
        use revision <- decode.field(2, decode.int)
        decode.success(Pending(active, desired, revision))
      },
    ),
  )
  Ok(list.first(rows) |> option.from_result)
}

const descendants =
  "WITH RECURSIVE descendants(id) AS (SELECT ? UNION SELECT f.session FROM session_family f JOIN descendants d ON f.parent=d.id) "

pub fn record(
  ledger: store.Store,
  request: Request,
) -> Result(Recorded, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(family.available_in(db, request.session))
      use current <- result.try(session_configuration.read_in(
        db,
        request.session,
      ))
      use _ <- result.try(
        case
          current.revision == request.expected.revision
          && current.family.revision == request.expected.family_revision
        {
          True -> Ok(Nil)
          False -> Error("configuration_changed")
        },
      )
      let arguments = [
        sqlight.text(request.session),
        sqlight.text(current.workspace),
        sqlight.text(request.session),
      ]
      let move_id =
        request.session
        <> ":"
        <> int.to_string(current.revision)
        <> ":"
        <> int.to_string(current.family.revision)
      let matching =
        "FROM sessions WHERE id IN (SELECT id FROM descendants) AND (COALESCE(desired_workspace,cwd)=? OR id=?)"
      use count <- result.try(store.one(
        db,
        descendants <> "SELECT COUNT(*) " <> matching,
        arguments,
        decode.field(0, decode.int, decode.success),
        "workspace family not found",
      ))
      use ids <- result.try(store.rows(
        db,
        descendants <> "SELECT id " <> matching <> " ORDER BY id LIMIT 200",
        arguments,
        decode.field(0, decode.string, decode.success),
      ))
      use _ <- result.try(
        store.run(
          db,
          descendants
            <> "UPDATE sessions SET desired_workspace=?,workspace_move_id=?,workspace_revision=workspace_revision+1,config_revision=config_revision+1 WHERE id IN (SELECT id FROM descendants) AND (COALESCE(desired_workspace,cwd)=? OR id=?)",
          [
            sqlight.text(request.session),
            sqlight.text(request.destination),
            sqlight.text(move_id),
            sqlight.text(current.workspace),
            sqlight.text(request.session),
          ],
        ),
      )
      use _ <- result.try(family.changed_in(db, request.session))
      Ok(Recorded(
        move_id,
        current.workspace,
        request.destination,
        count,
        ids,
        count > list.length(ids),
      ))
    })
  })
}

/// Counts come from the recorded move, including sessions omitted from its
/// bounded notification list. A later move or deletion is reported separately.
pub fn report(
  ledger: store.Store,
  recorded: Recorded,
) -> Result(Report, String) {
  store.query(ledger, fn(db) {
    use counts <- result.try(store.one(
      db,
      "SELECT COUNT(*),COALESCE(SUM(desired_workspace IS NULL AND cwd=?),0),COALESCE(SUM(desired_workspace IS NOT NULL),0) FROM sessions WHERE workspace_move_id=?",
      [sqlight.text(recorded.destination), sqlight.text(recorded.move_id)],
      {
        use matched <- decode.field(0, decode.int)
        use applied <- decode.field(1, decode.int)
        use deferred <- decode.field(2, decode.int)
        decode.success(#(matched, applied, deferred))
      },
      "workspace report unavailable",
    ))
    use applied_ids <- result.try(store.rows(
      db,
      "SELECT id FROM sessions WHERE workspace_move_id=? AND desired_workspace IS NULL AND cwd=? ORDER BY id LIMIT 200",
      [sqlight.text(recorded.move_id), sqlight.text(recorded.destination)],
      decode.field(0, decode.string, decode.success),
    ))
    use deferred_ids <- result.try(store.rows(
      db,
      "SELECT id FROM sessions WHERE workspace_move_id=? AND desired_workspace IS NOT NULL ORDER BY id LIMIT 200",
      [sqlight.text(recorded.move_id)],
      decode.field(0, decode.string, decode.success),
    ))
    Ok(Report(
      counts.1,
      counts.2,
      applied_ids,
      deferred_ids,
      counts.1 > list.length(applied_ids)
        || counts.2 > list.length(deferred_ids),
      recorded.affected_count - counts.1 - counts.2,
    ))
  })
}

/// Page the recorded membership without loading an entire family or starting
/// parked actors. Applied members retain their marker for the final report.
pub fn pending_members(
  ledger: store.Store,
  move_id: String,
  after_id: Option(String),
  limit: Int,
) -> Result(List(String), String) {
  case limit >= 1 && limit <= 200 {
    False -> Error("workspace member page limit must be between 1 and 200")
    True ->
      store.read(
        ledger,
        "SELECT id FROM sessions WHERE workspace_move_id=? AND desired_workspace IS NOT NULL AND (? IS NULL OR id>?) ORDER BY id LIMIT ?",
        [
          sqlight.text(move_id),
          sqlight.nullable(sqlight.text, after_id),
          sqlight.nullable(sqlight.text, after_id),
          sqlight.int(limit),
        ],
        decode.field(0, decode.string, decode.success),
      )
  }
}

/// Cleanup may have taken time. Superseded intent stays pending, and cannot
/// be cleared by the completion of an older move.
pub fn applied(
  ledger: store.Store,
  session: String,
  pending: Pending,
) -> Result(Bool, String) {
  store.query(ledger, fn(db) {
    use rows <- result.try(store.rows(
      db,
      "UPDATE sessions SET cwd=desired_workspace,desired_workspace=NULL WHERE id=? AND workspace_revision=? AND desired_workspace=? RETURNING id",
      [
        sqlight.text(session),
        sqlight.int(pending.revision),
        sqlight.text(pending.desired),
      ],
      decode.field(0, decode.string, decode.success),
    ))
    Ok(rows != [])
  })
}
