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

pub const schema = "CREATE TABLE IF NOT EXISTS operations(id TEXT PRIMARY KEY,fingerprint TEXT NOT NULL,kind TEXT NOT NULL,target TEXT NOT NULL,status TEXT NOT NULL CHECK(status IN ('accepted','rejected')),http_status INTEGER NOT NULL,response TEXT NOT NULL,created_at INTEGER NOT NULL,terminal_at INTEGER,delivery TEXT CHECK(delivery IN ('pending','committed','cancelled')),blocking_reason TEXT,committed_seq INTEGER); CREATE INDEX IF NOT EXISTS operations_expiry ON operations(terminal_at) WHERE terminal_at IS NOT NULL; CREATE TABLE IF NOT EXISTS pending_inputs(seq INTEGER PRIMARY KEY AUTOINCREMENT,operation_id TEXT NOT NULL UNIQUE REFERENCES operations(id),session TEXT NOT NULL REFERENCES sessions(id),payload BLOB NOT NULL,accepted_at INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS pending_inputs_session ON pending_inputs(session,seq); CREATE TABLE IF NOT EXISTS submission_events(session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER NOT NULL,operation_id TEXT NOT NULL UNIQUE,payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS submission_events_session ON submission_events(session,seq); CREATE TABLE IF NOT EXISTS continuation_markers(operation_id TEXT PRIMARY KEY,session TEXT NOT NULL REFERENCES sessions(id),seq INTEGER NOT NULL,payload BLOB NOT NULL); CREATE INDEX IF NOT EXISTS continuation_markers_session ON continuation_markers(session,seq);"

pub type Request {
  Request(id: String, fingerprint: String, kind: String, target: String)
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
  )
}

pub type Pending {
  Pending(id: String, session: String, payload: BitArray, accepted_at: Int)
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
fn decode_display(payload: BitArray) -> Display

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
  decode.success(Receipt(
    Request(id, fingerprint, kind, target),
    status,
    http_status,
    response,
    created_at,
    delivery,
    blocking,
    committed_seq,
  ))
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
    "SELECT id,fingerprint,kind,target,status,http_status,response,created_at,delivery,blocking_reason,committed_seq FROM operations WHERE id=?",
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
      // Creation learns its target when the session row is allocated. Its
      // fingerprint identifies the original request before that allocation.
      let original = receipt.operation
      let matches =
        original.id == request.id
        && original.fingerprint == request.fingerprint
        && original.kind == request.kind
        && { request.kind == "create" || original.target == request.target }
      case matches {
        True -> Ok(Some(receipt))
        False -> Error("operation_conflict")
      }
    }
    None -> validate_id(request.id, usage.now()) |> result.replace(None)
  }
}

/// Runs the mutation and saves its admission response on this same connection.
/// A duplicate does not call the mutation, even when the session was deleted.
pub fn admit(
  ledger: store.Store,
  request: Request,
  http_status: Int,
  response: String,
  delivery: Option(String),
  mutate: fn(sqlight.Connection) -> Result(Nil, String),
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
          ))
        }
      }
    })
  })
}

pub fn admit_pending(
  ledger: store.Store,
  request: Request,
  payload: BitArray,
  http_status: Int,
  response: String,
) -> Result(Receipt, String) {
  admit(ledger, request, http_status, response, Some("pending"), fn(db) {
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
  http_status: Int,
  response: String,
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
            http_status,
            response,
            now,
            None,
          ))
          Ok(Receipt(
            request,
            "rejected",
            http_status,
            response,
            now,
            None,
            None,
            None,
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
    "INSERT INTO operations(id,fingerprint,kind,target,status,http_status,response,created_at,terminal_at,delivery) VALUES(?,?,?,?,?,?,?,?,?,?)",
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
    ],
  )
}

pub fn pending(
  ledger: store.Store,
  session: String,
) -> Result(List(Pending), String) {
  store.read(
    ledger,
    "SELECT operation_id,session,payload,accepted_at FROM pending_inputs WHERE session=? ORDER BY seq",
    [sqlight.text(session)],
    {
      use id <- decode.field(0, decode.string)
      use session <- decode.field(1, decode.string)
      use payload <- decode.field(2, decode.bit_array)
      use accepted_at <- decode.field(3, decode.int)
      decode.success(Pending(id, session, payload, accepted_at))
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
  now: Int,
) -> Result(Nil, String) {
  list.try_each(submissions, fn(submission) {
    let Commit(id, offset, display) = submission
    use _ <- result.try(store.one(
      db,
      "SELECT operation_id FROM pending_inputs WHERE operation_id=? AND session=?",
      [sqlight.text(id), sqlight.text(session)],
      decode.field(0, decode.string, decode.success),
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
          "INSERT INTO continuation_markers(operation_id,session,seq,payload) VALUES(?,?,?,?)",
          [
            sqlight.text(id),
            sqlight.text(session),
            sqlight.int(seq),
            sqlight.blob(encode_display(display)),
          ],
        )
    })
    use _ <- result.try(
      store.run(
        db,
        "UPDATE operations SET delivery='committed',terminal_at=?,committed_seq=?,blocking_reason=NULL WHERE id=? AND delivery='pending'",
        [sqlight.int(now), sqlight.int(seq), sqlight.text(id)],
      ),
    )
    store.run(
      db,
      "DELETE FROM pending_inputs WHERE operation_id=? AND session=?",
      [sqlight.text(id), sqlight.text(session)],
    )
  })
}

/// One row's display metadata without scanning the session's submissions.
pub fn committed_input(
  ledger: store.Store,
  session: String,
  seq: Int,
) -> Result(Option(Display), String) {
  use rows <- result.try(store.read(
    ledger,
    "SELECT payload FROM submission_events WHERE session=? AND seq=?",
    [sqlight.text(session), sqlight.int(seq)],
    decode.field(0, decode.bit_array, decode.success),
  ))
  Ok(list.first(rows) |> option.from_result |> option.map(decode_display))
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
  store.write(
    ledger,
    "DELETE FROM operations WHERE id IN (SELECT id FROM operations WHERE terminal_at IS NOT NULL AND terminal_at<? ORDER BY terminal_at LIMIT 128)",
    [sqlight.int(usage.now() - retention_ms)],
  )
}

@external(erlang, "albedo_operations", "validate_id")
pub fn validate_id(id: String, now: Int) -> Result(Nil, String)
