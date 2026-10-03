//// Durable admissions. Pending inputs and their receipts share a transaction;
//// receipts deliberately have no session foreign key and survive deletion.

import albedo/daemon/store
import albedo/daemon/usage
import gleam/dynamic/decode
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import sqlight

pub const retention_ms = 604_800_000

pub const schema = "CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,kind TEXT NOT NULL,target TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('accepted','rejected')),http_status INTEGER NOT NULL,response TEXT NOT NULL,created_at INTEGER NOT NULL,terminal_at INTEGER,delivery TEXT CHECK(delivery IN ('pending','committed','cancelled')),blocking_reason TEXT,committed_seq INTEGER); CREATE INDEX IF NOT EXISTS operations_expiry ON operations(terminal_at) WHERE terminal_at IS NOT NULL; CREATE TABLE IF NOT EXISTS pending_inputs(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE REFERENCES operations(id),session TEXT NOT NULL REFERENCES sessions(id),payload BLOB NOT NULL,accepted_at INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS pending_inputs_session ON pending_inputs(session,seq); CREATE TABLE IF NOT EXISTS submission_events(session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER NOT NULL,operation_id TEXT NOT NULL,payload BLOB NOT NULL,UNIQUE(session,operation_id)); CREATE INDEX IF NOT EXISTS submission_events_session ON submission_events(session,seq); CREATE TABLE IF NOT EXISTS continuation_markers(operation_id TEXT NOT NULL,session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER NOT NULL,payload BLOB NOT NULL,UNIQUE(session,operation_id)); CREATE INDEX IF NOT EXISTS continuation_markers_session ON continuation_markers(session,seq);"

pub type Request {
  Request(
    id: String,
    fingerprint: String,
    kind: String,
    target: String,
    client_id: Option(String),
  )
}

pub type Receipt {
  Receipt(
    operation: Request,
    status: String,
    http_status: Int,
    response: String,
    created_at: Int,
    delivery: Option(String),
    blocking_reason: Option(String),
    committed_seq: Option(Int),
    rejection: Option(Rejection),
  )
}

pub type Rejection {
  Rejection(status: Int, code: String, detail: String)
}

pub type Pending {
  Pending(
    id: String,
    session: String,
    payload: BitArray,
    accepted_at: Int,
    acceptance_order: Int,
    kind: String,
    blocking_reason: Option(String),
    client_id: Option(String),
  )
}

pub type TurnOutcome {
  TurnOutcome(id: String, state: String, started_at: Int, ended_at: Option(Int))
}

pub type InputOutcome {
  InputOutcome(
    receipt: Receipt,
    acceptance_order: Int,
    turn: Option(TurnOutcome),
  )
}

/// These facts share the transcript connection and remain independent of
/// session rows, so deleting a session does not erase retained input decisions.
pub fn initialise(db: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(
    store.add_columns(db, "operations", [
      #("acceptance_order", "INTEGER"),
      #("turn_id", "TEXT"),
      #("client_id", "TEXT"),
      #("rejection_code", "TEXT"),
      #("rejection_detail", "TEXT"),
    ]),
  )
  use _ <- result.try(
    store.add_columns(db, "continuation_markers", [
      #("timestamp", "INTEGER"),
      #("turn_id", "TEXT"),
    ]),
  )
  use _ <- result.try(scope_display_metadata(db))
  use _ <- result.try(store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS input_turns(id TEXT PRIMARY KEY,session TEXT NOT NULL,state TEXT NOT NULL CHECK(state IN ('running','completed','interrupted','failed','abandoned')),started_at INTEGER NOT NULL,ended_at INTEGER); CREATE INDEX IF NOT EXISTS input_turns_session ON input_turns(session); CREATE INDEX IF NOT EXISTS input_turns_expiry ON input_turns(ended_at) WHERE ended_at IS NOT NULL; CREATE INDEX IF NOT EXISTS operations_turn ON operations(turn_id) WHERE turn_id IS NOT NULL;",
  ))
  // Pending rows retained their original admission ordering before protocol 3.
  use _ <- result.try(store.exec(
    db,
    "UPDATE operations SET acceptance_order=(SELECT seq FROM pending_inputs WHERE operation_id=operations.id) WHERE acceptance_order IS NULL AND id IN (SELECT operation_id FROM pending_inputs); UPDATE sessions SET input_order=MAX(input_order,COALESCE((SELECT MAX(acceptance_order) FROM operations WHERE target=sessions.id),0));",
  ))
  Ok(Nil)
}

// Forks retain the original immutable input identity in their own historical
// metadata. Receipt and pending-input admission identity remains global.
fn scope_display_metadata(db: sqlight.Connection) -> Result(Nil, String) {
  store.transaction(db, fn() {
    list.try_each(
      [
        #(
          "submission_events",
          "session,seq,operation_id,payload",
          "session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER NOT NULL,operation_id TEXT NOT NULL,payload BLOB NOT NULL,UNIQUE(session,operation_id)",
        ),
        #(
          "continuation_markers",
          "operation_id,session,seq,payload,timestamp,turn_id",
          "operation_id TEXT NOT NULL,session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER NOT NULL,payload BLOB NOT NULL,timestamp INTEGER,turn_id TEXT,UNIQUE(session,operation_id)",
        ),
      ],
      fn(metadata) {
        use global <- result.try(store.one(
          db,
          "SELECT EXISTS(SELECT 1 FROM pragma_index_list(?) i JOIN pragma_index_info(i.name) p WHERE i.[unique]=1 GROUP BY i.name HAVING COUNT(*)=1 AND MIN(p.name)='operation_id')",
          [sqlight.text(metadata.0)],
          decode.field(0, decode.int, decode.success),
          "input metadata schema unavailable",
        ))
        case global {
          0 -> Ok(Nil)
          _ ->
            store.exec(
              db,
              "CREATE TABLE "
                <> metadata.0
                <> "_scoped("
                <> metadata.2
                <> "); INSERT INTO "
                <> metadata.0
                <> "_scoped(rowid,"
                <> metadata.1
                <> ") SELECT rowid,"
                <> metadata.1
                <> " FROM "
                <> metadata.0
                <> "; DROP TABLE "
                <> metadata.0
                <> "; ALTER TABLE "
                <> metadata.0
                <> "_scoped RENAME TO "
                <> metadata.0
                <> "; CREATE INDEX "
                <> metadata.0
                <> "_session ON "
                <> metadata.0
                <> "(session,seq);",
            )
        }
      },
    )
  })
}

pub fn input_outcome(
  ledger: store.Store,
  id: String,
) -> Result(Option(InputOutcome), String) {
  store.query(ledger, fn(db) {
    use receipt <- result.try(lookup_in(db, id))
    case receipt {
      None -> Ok(None)
      Some(receipt) -> {
        use order <- result.try(store.one(
          db,
          "SELECT COALESCE(acceptance_order,0) FROM operations WHERE id=?",
          [sqlight.text(id)],
          decode.field(0, decode.int, decode.success),
          "input decision disappeared",
        ))
        use turns <- result.try(
          store.rows(
            db,
            "SELECT t.id,t.state,t.started_at,t.ended_at FROM input_turns t JOIN operations o ON o.turn_id=t.id WHERE o.id=?",
            [sqlight.text(id)],
            {
              use id <- decode.field(0, decode.string)
              use state <- decode.field(1, decode.string)
              use started <- decode.field(2, decode.int)
              use ended <- decode.field(3, decode.optional(decode.int))
              decode.success(TurnOutcome(id, state, started, ended))
            },
          ),
        )
        Ok(
          Some(InputOutcome(
            receipt,
            order,
            list.first(turns) |> option.from_result,
          )),
        )
      }
    }
  })
}

/// Original upload metadata; the transcript and image store own its content.
pub type ImageMetadata {
  ImageMetadata(mime_type: String, width: Int, height: Int, bytes: Int)
}

pub type Display {
  Display(
    text: String,
    source: String,
    client_id: String,
    operation_id: Option(String),
    image: Option(ImageMetadata),
  )
}

/// The transcript offset is absent for continuations, which append no row.
pub type Commit {
  Commit(id: String, offset: Option(Int), display: Display)
}

@external(erlang, "erlang", "term_to_binary")
fn encode_display(display: Display) -> BitArray

@external(erlang, "albedo_operations", "decode_display")
pub fn decode_display(payload: BitArray) -> Display

fn receipt_decoder() -> decode.Decoder(Receipt) {
  use id <- decode.field(0, decode.string)
  use fingerprint <- decode.field(1, decode.string)
  use kind <- decode.field(2, decode.string)
  use target <- decode.field(3, decode.string)
  use status <- decode.field(4, decode.string)
  use http_status <- decode.field(5, decode.int)
  use response <- decode.field(6, decode.string)
  use created_at <- decode.field(7, decode.int)
  use delivery <- decode.field(8, decode.optional(decode.string))
  use blocking <- decode.field(9, decode.optional(decode.string))
  use committed_seq <- decode.field(10, decode.optional(decode.int))
  use client_id <- decode.field(11, decode.optional(decode.string))
  use rejection_code <- decode.field(12, decode.optional(decode.string))
  use rejection_detail <- decode.field(13, decode.optional(decode.string))
  decode.success(
    Receipt(
      Request(id, fingerprint, kind, target, client_id),
      status,
      http_status,
      response,
      created_at,
      delivery,
      blocking,
      committed_seq,
      case rejection_code, rejection_detail {
        Some(code), Some(detail) -> Some(Rejection(http_status, code, detail))
        _, _ -> None
      },
    ),
  )
}

pub fn lookup(
  ledger: store.Store,
  id: String,
) -> Result(Option(Receipt), String) {
  store.query(ledger, lookup_in(_, id))
}

pub fn lookup_in(
  db: sqlight.Connection,
  id: String,
) -> Result(Option(Receipt), String) {
  use rows <- result.try(store.rows(
    db,
    "SELECT id,fingerprint,kind,target,status,http_status,response,created_at,delivery,blocking_reason,committed_seq,client_id,rejection_code,rejection_detail FROM operations WHERE id=?",
    [sqlight.text(id)],
    receipt_decoder(),
  ))
  Ok(list.first(rows) |> option.from_result)
}

/// Existing receipts win over all mutable validation and UUID age checks.
pub fn check(
  ledger: store.Store,
  request: Request,
) -> Result(Option(Receipt), String) {
  store.query(ledger, check_in(_, request))
}

pub fn check_in(
  db: sqlight.Connection,
  request: Request,
) -> Result(Option(Receipt), String) {
  use receipt <- result.try(lookup_in(db, request.id))
  case receipt {
    Some(receipt) -> {
      let original = receipt.operation
      let matches =
        original.id == request.id
        && original.fingerprint == request.fingerprint
        && original.kind == request.kind
        && original.target == request.target
      case matches {
        True -> Ok(Some(receipt))
        False -> Error("operation_conflict")
      }
    }
    None -> validate_id(request.id, usage.now()) |> result.replace(None)
  }
}

/// Admission on the caller's transaction connection. A child and its first
/// input use this boundary so neither can commit without the other.
pub fn admit_in(
  db: sqlight.Connection,
  request: Request,
  http_status: Int,
  response: String,
  delivery: Option(String),
  mutate: fn(sqlight.Connection) -> Result(Nil, String),
) -> Result(Receipt, String) {
  use previous <- result.try(check_in(db, request))
  case previous {
    Some(receipt) -> Ok(receipt)
    None -> {
      let now = usage.now()
      use _ <- result.try(insert(
        db,
        request,
        "accepted",
        http_status,
        response,
        now,
        delivery,
      ))
      use _ <- result.try(mutate(db))
      Ok(Receipt(
        request,
        "accepted",
        http_status,
        response,
        now,
        delivery,
        None,
        None,
        None,
      ))
    }
  }
}

pub fn admit_pending(
  ledger: store.Store,
  request: Request,
  payload: BitArray,
  http_status: Int,
  response: String,
) -> Result(Receipt, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      admit_pending_in(db, request, payload, http_status, response)
    })
  })
}

pub fn admit_pending_in(
  db: sqlight.Connection,
  request: Request,
  payload: BitArray,
  http_status: Int,
  response: String,
) -> Result(Receipt, String) {
  admit_in(db, request, http_status, response, Some("pending"), fn(db) {
    use available <- result.try(store.one(
      db,
      "SELECT deletion_id IS NULL FROM sessions WHERE id=?",
      [sqlight.text(request.target)],
      decode.field(0, decode.int, decode.success),
      "session not found",
    ))
    use _ <- result.try(case available {
      1 -> Ok(Nil)
      _ -> Error("deletion_in_progress")
    })
    use _ <- result.try(
      store.run(db, "UPDATE sessions SET input_order=input_order+1 WHERE id=?", [
        sqlight.text(request.target),
      ]),
    )
    use _ <- result.try(
      store.run(
        db,
        "UPDATE operations SET acceptance_order=(SELECT input_order FROM sessions WHERE id=?) WHERE id=?",
        [sqlight.text(request.target), sqlight.text(request.id)],
      ),
    )
    store.run(
      db,
      "INSERT INTO pending_inputs(operation_id,session,payload,accepted_at) VALUES(?,?,?,?)",
      [
        sqlight.text(request.id),
        sqlight.text(request.target),
        sqlight.blob(payload),
        sqlight.int(usage.now()),
      ],
    )
  })
}

pub fn reject(
  ledger: store.Store,
  request: Request,
  rejection: Rejection,
) -> Result(Receipt, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use previous <- result.try(check_in(db, request))
      case previous {
        Some(receipt) -> Ok(receipt)
        None -> {
          let now = usage.now()
          use _ <- result.try(insert(
            db,
            request,
            "rejected",
            rejection.status,
            "",
            now,
            None,
          ))
          use _ <- result.try(
            store.run(
              db,
              "UPDATE operations SET rejection_code=?,rejection_detail=? WHERE id=?",
              [
                sqlight.text(rejection.code),
                sqlight.text(rejection.detail),
                sqlight.text(request.id),
              ],
            ),
          )
          Ok(Receipt(
            request,
            "rejected",
            rejection.status,
            "",
            now,
            None,
            None,
            None,
            Some(rejection),
          ))
        }
      }
    })
  })
}

fn insert(
  db: sqlight.Connection,
  request: Request,
  status: String,
  http_status: Int,
  response: String,
  now: Int,
  delivery: Option(String),
) -> Result(Nil, String) {
  store.run(
    db,
    "INSERT INTO operations(id,fingerprint,kind,target,status,http_status,response,created_at,terminal_at,delivery,client_id) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
    [
      sqlight.text(request.id),
      sqlight.text(request.fingerprint),
      sqlight.text(request.kind),
      sqlight.text(request.target),
      sqlight.text(status),
      sqlight.int(http_status),
      sqlight.text(response),
      sqlight.int(now),
      sqlight.nullable(sqlight.int, case delivery {
        Some("pending") -> None
        _ -> Some(now)
      }),
      sqlight.nullable(sqlight.text, delivery),
      sqlight.nullable(sqlight.text, request.client_id),
    ],
  )
}

pub fn pending(
  ledger: store.Store,
  session: String,
) -> Result(List(Pending), String) {
  store.query(ledger, pending_in(_, session))
}

pub fn pending_in(
  db: sqlight.Connection,
  session: String,
) -> Result(List(Pending), String) {
  store.rows(
    db,
    "SELECT p.operation_id,p.session,p.payload,p.accepted_at,o.acceptance_order,o.kind,o.blocking_reason,o.client_id FROM pending_inputs p JOIN operations o ON o.id=p.operation_id WHERE p.session=? ORDER BY o.acceptance_order",
    [sqlight.text(session)],
    {
      use id <- decode.field(0, decode.string)
      use session <- decode.field(1, decode.string)
      use payload <- decode.field(2, decode.bit_array)
      use accepted_at <- decode.field(3, decode.int)
      use order <- decode.field(4, decode.int)
      use kind <- decode.field(5, decode.string)
      use blocking <- decode.field(6, decode.optional(decode.string))
      use client_id <- decode.field(7, decode.optional(decode.string))
      decode.success(Pending(
        id,
        session,
        payload,
        accepted_at,
        order,
        kind,
        blocking,
        client_id,
      ))
    },
  )
}

pub fn pending_sessions(ledger: store.Store) -> Result(List(String), String) {
  store.read(
    ledger,
    "SELECT session FROM pending_inputs GROUP BY session ORDER BY MIN(seq)",
    [],
    decode.field(0, decode.string, decode.success),
  )
}

pub fn block(
  ledger: store.Store,
  ids: List(String),
  reason: String,
) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    list.try_each(ids, fn(id) {
      store.run(
        db,
        "UPDATE operations SET blocking_reason=? WHERE id=? AND delivery='pending'",
        [sqlight.text(reason), sqlight.text(id)],
      )
    })
  })
}

/// Called only within the transaction that appends these inputs.
pub fn committed(
  db: sqlight.Connection,
  session: String,
  submissions: List(Commit),
  first_seq: Int,
  last_seq: Int,
  turn_id: Option(String),
) -> Result(Nil, String) {
  list.try_each(submissions, fn(submission) {
    let Commit(id, offset, display) = submission
    use accepted_at <- result.try(store.one(
      db,
      "SELECT accepted_at FROM pending_inputs WHERE operation_id=? AND session=?",
      [sqlight.text(id), sqlight.text(session)],
      decode.field(0, decode.int, decode.success),
      "pending operation missing",
    ))
    let seq = case offset {
      Some(offset) -> first_seq + offset
      None -> last_seq
    }
    use _ <- result.try(case offset {
      Some(_) ->
        store.run(
          db,
          "INSERT INTO submission_events(session,seq,operation_id,payload) VALUES(?,?,?,?)",
          [
            sqlight.text(session),
            sqlight.int(seq),
            sqlight.text(id),
            sqlight.blob(encode_display(display)),
          ],
        )
      None ->
        store.run(
          db,
          "INSERT INTO continuation_markers(operation_id,session,seq,payload,timestamp,turn_id) VALUES(?,?,?,?,?,?)",
          [
            sqlight.text(id),
            sqlight.text(session),
            sqlight.int(seq),
            sqlight.blob(encode_display(display)),
            sqlight.int(accepted_at),
            sqlight.nullable(sqlight.text, turn_id),
          ],
        )
    })
    use _ <- result.try(
      store.run(
        db,
        "UPDATE operations SET delivery='committed',terminal_at=NULL,committed_seq=?,turn_id=?,blocking_reason=NULL WHERE id=? AND delivery='pending'",
        [
          sqlight.int(seq),
          sqlight.nullable(sqlight.text, turn_id),
          sqlight.text(id),
        ],
      ),
    )
    store.run(
      db,
      "DELETE FROM pending_inputs WHERE operation_id=? AND session=?",
      [sqlight.text(id), sqlight.text(session)],
    )
  })
}

pub fn begin_turn_in(
  db: sqlight.Connection,
  session: String,
  id: String,
  now: Int,
  workspace: Option(String),
) -> Result(Nil, String) {
  // An existing run may finish or consume steering in its original workspace.
  // A new run must use the applied destination, checked in the input transaction.
  use allowed <- result.try(store.one(
    db,
    "SELECT EXISTS(SELECT 1 FROM input_turns WHERE id=? AND session=? AND state='running') OR (? IS NOT NULL AND NOT EXISTS(SELECT 1 FROM input_turns WHERE id=?) AND EXISTS(SELECT 1 FROM sessions WHERE id=? AND deletion_id IS NULL AND desired_workspace IS NULL AND cwd=?))",
    [
      sqlight.text(id),
      sqlight.text(session),
      sqlight.nullable(sqlight.text, workspace),
      sqlight.text(id),
      sqlight.text(session),
      sqlight.nullable(sqlight.text, workspace),
    ],
    decode.field(0, decode.int, decode.success),
    "turn admission unavailable",
  ))
  use _ <- result.try(case allowed {
    1 -> Ok(Nil)
    _ -> Error("workspace change must be applied before starting a turn")
  })
  store.run(
    db,
    "INSERT INTO input_turns(id,session,state,started_at) VALUES(?,?,'running',?) ON CONFLICT(id) DO NOTHING",
    [sqlight.text(id), sqlight.text(session), sqlight.int(now)],
  )
}

pub fn finish_turn_in(
  db: sqlight.Connection,
  id: String,
  state: String,
  now: Int,
) -> Result(Nil, String) {
  use _ <- result.try(case state {
    "completed" | "interrupted" | "failed" | "abandoned" -> Ok(Nil)
    _ -> Error("invalid terminal turn state")
  })
  use _ <- result.try(
    store.run(
      db,
      "UPDATE input_turns SET state=?,ended_at=? WHERE id=? AND state='running'",
      [sqlight.text(state), sqlight.int(now), sqlight.text(id)],
    ),
  )
  store.run(
    db,
    "UPDATE operations SET terminal_at=(SELECT ended_at FROM input_turns WHERE id=?) WHERE turn_id=? AND delivery='committed' AND terminal_at IS NULL AND EXISTS(SELECT 1 FROM input_turns WHERE id=? AND ended_at IS NOT NULL)",
    [sqlight.text(id), sqlight.text(id), sqlight.text(id)],
  )
}

/// Startup records the lost run's outcome before another run can resume work.
pub fn abandon_unfinished(db: sqlight.Connection) -> Result(Nil, String) {
  let now = usage.now()
  use runs <- result.try(store.rows(
    db,
    "SELECT id FROM input_turns WHERE state='running'",
    [],
    decode.field(0, decode.string, decode.success),
  ))
  store.transaction(db, fn() {
    list.try_each(runs, finish_turn_in(db, _, "abandoned", now))
  })
}

pub fn cancel(ledger: store.Store, session: String) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() { cancel_in(db, session) })
  })
}

/// Cancels only the waiting inputs selected by submission ownership.
pub fn cancel_inputs(
  ledger: store.Store,
  session: String,
  ids: List(String),
) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      list.try_each(ids, fn(id) {
        use _ <- result.try(
          store.run(
            db,
            "UPDATE operations SET delivery='cancelled',terminal_at=?,blocking_reason=NULL WHERE id IN (SELECT operation_id FROM pending_inputs WHERE session=? AND operation_id=?)",
            [sqlight.int(usage.now()), sqlight.text(session), sqlight.text(id)],
          ),
        )
        store.run(
          db,
          "DELETE FROM pending_inputs WHERE session=? AND operation_id=?",
          [sqlight.text(session), sqlight.text(id)],
        )
      })
    })
  })
}

/// Cancel the captured prefix only; later admissions belong to a newer request.
pub fn cancel_through(
  ledger: store.Store,
  session: String,
  through_order: Int,
) -> Result(List(String), String) {
  store.query(ledger, fn(db) {
    store.transaction(db, fn() {
      use ids <- result.try(store.rows(
        db,
        "SELECT p.operation_id FROM pending_inputs p JOIN operations o ON o.id=p.operation_id WHERE p.session=? AND o.acceptance_order<=? ORDER BY o.acceptance_order",
        [sqlight.text(session), sqlight.int(through_order)],
        decode.field(0, decode.string, decode.success),
      ))
      use _ <- result.try(
        store.run(
          db,
          "UPDATE operations SET delivery='cancelled',terminal_at=?,blocking_reason=NULL WHERE id IN (SELECT operation_id FROM pending_inputs WHERE session=?) AND acceptance_order<=?",
          [
            sqlight.int(usage.now()),
            sqlight.text(session),
            sqlight.int(through_order),
          ],
        ),
      )
      use _ <- result.try(
        store.run(
          db,
          "DELETE FROM pending_inputs WHERE session=? AND operation_id IN (SELECT id FROM operations WHERE target=? AND delivery='cancelled' AND acceptance_order<=?)",
          [
            sqlight.text(session),
            sqlight.text(session),
            sqlight.int(through_order),
          ],
        ),
      )
      Ok(ids)
    })
  })
}

/// Called only after the session owner and kernel have stopped.
pub fn finish_deleted_session_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use runs <- result.try(store.rows(
    db,
    "SELECT id FROM input_turns WHERE session=? AND state='running'",
    [sqlight.text(session)],
    decode.field(0, decode.string, decode.success),
  ))
  list.try_each(runs, finish_turn_in(db, _, "interrupted", usage.now()))
}

/// Cancel pending inputs for exactly the claimed deletion membership.
pub fn cancel_deletion_in(
  db: sqlight.Connection,
  claim: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "UPDATE operations SET delivery='cancelled',terminal_at=?,blocking_reason=NULL WHERE id IN (SELECT p.operation_id FROM pending_inputs p JOIN sessions s ON s.id=p.session WHERE s.deletion_id=?)",
      [sqlight.int(usage.now()), sqlight.text(claim)],
    ),
  )
  store.run(
    db,
    "DELETE FROM pending_inputs WHERE session IN (SELECT id FROM sessions WHERE deletion_id=?)",
    [sqlight.text(claim)],
  )
}

pub fn cancel_in(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  use _ <- result.try(
    store.run(
      db,
      "UPDATE operations SET delivery='cancelled',terminal_at=?,blocking_reason=NULL WHERE id IN (SELECT operation_id FROM pending_inputs WHERE session=?)",
      [sqlight.int(usage.now()), sqlight.text(session)],
    ),
  )
  store.run(db, "DELETE FROM pending_inputs WHERE session=?", [
    sqlight.text(session),
  ])
}

/// Each call removes at most 128 terminal receipts; pending work never ages out.
pub fn prune(ledger: store.Store) -> Result(Nil, String) {
  store.query(ledger, fn(db) {
    use _ <- result.try(
      store.run(
        db,
        "DELETE FROM operations WHERE id IN (SELECT id FROM operations WHERE terminal_at IS NOT NULL AND terminal_at<? ORDER BY terminal_at LIMIT 128)",
        [sqlight.int(usage.now() - retention_ms)],
      ),
    )
    store.run(
      db,
      "DELETE FROM input_turns WHERE id IN (SELECT t.id FROM input_turns t WHERE t.ended_at<? AND NOT EXISTS(SELECT 1 FROM sessions s WHERE s.id=t.session) AND NOT EXISTS(SELECT 1 FROM operations o WHERE o.turn_id=t.id) LIMIT 128)",
      [sqlight.int(usage.now() - retention_ms)],
    )
  })
}

@external(erlang, "albedo_operations", "validate_id")
pub fn validate_id(id: String, now: Int) -> Result(Nil, String)
