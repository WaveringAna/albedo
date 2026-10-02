//// The daemon's half of a detached kernel's durable session layer.
////
//// One row per session names its kernel: where its run directory is, the
//// token an attach presents, the workspace and modules it booted with, the
//// last sequence number the daemon sent it, and the process groups it owns,
//// so a kernel found dead after a restart still has its jobs ended. Frames
//// the daemon sent and the kernel has not acknowledged stay in
//// `kernel_outbox`, so a reattach (or a restarted daemon) resends them.
//// `kernel_calls` remembers every host call the kernel made until the kernel
//// has its reply, so a replayed call never runs twice.

import albedo/daemon/store
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option}
import gleam/result
import sqlight

/// Frames and bytes one kernel's outbox keeps; past either, the oldest go.
const outbox_frames = 2048

const outbox_bytes = 67_108_864

pub type Record {
  Record(
    session: String,
    kernel: String,
    token: String,
    run_dir: String,
    cwd: String,
    modules: String,
    out_seq: Int,
    /// `{pid, pgid, leader, groups}`: the kernel's identity from its last
    /// hello and its job groups by job id, as JSON.
    owned: String,
  )
}

/// What the ledger knows about a host call id the kernel sent.
pub type CallState {
  /// Never seen: run it.
  Fresh
  /// Answered already; the reply is still in the outbox.
  Answered
  /// Started by an earlier daemon that never answered: effects unknown.
  Unknown
}

/// The callbacks the erlang port owner persists through, bound to one kernel.
pub type Link {
  Link(
    persist: fn(Int, String) -> Nil,
    ack: fn(Int) -> Nil,
    pending: fn() -> List(#(Int, String)),
    call: fn(String) -> CallState,
    reply: fn(String, Int, String) -> Nil,
    record: fn(String) -> Nil,
    forget: fn() -> Nil,
    own: fn(String) -> Nil,
  )
}

pub fn apply(db: sqlight.Connection) -> Result(Nil, String) {
  use _ <- result.try(store.exec(
    db,
    "CREATE TABLE IF NOT EXISTS kernel_links (
      session TEXT PRIMARY KEY, kernel TEXT NOT NULL UNIQUE, token TEXT NOT NULL,
      run_dir TEXT NOT NULL, cwd TEXT NOT NULL, modules TEXT NOT NULL,
      pid INTEGER, pgid INTEGER, leader TEXT, epoch INTEGER NOT NULL DEFAULT 0,
      out_seq INTEGER NOT NULL DEFAULT 0, groups TEXT NOT NULL DEFAULT '{}',
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')));
    CREATE TABLE IF NOT EXISTS kernel_outbox (
      session TEXT NOT NULL, kernel TEXT NOT NULL, seq INTEGER NOT NULL,
      frame BLOB NOT NULL, PRIMARY KEY (session, kernel, seq));
    CREATE TABLE IF NOT EXISTS kernel_calls (
      kernel TEXT NOT NULL, call TEXT NOT NULL, reply_seq INTEGER,
      PRIMARY KEY (kernel, call));",
  ))
  store.add_columns(db, "kernel_links", [
    #("groups", "TEXT NOT NULL DEFAULT '{}'"),
  ])
}

/// Record a kernel about to boot, replacing whatever the session had.
pub fn create(storage: store.Store, record: Record) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      // Embedded runtimes may boot kernels without installing the python
      // extension that owns these tables.
      use _ <- result.try(apply(db))
      use _ <- result.try(forget_session(db, record.session))
      store.run(
        db,
        "INSERT INTO kernel_links(session,kernel,token,run_dir,cwd,modules) VALUES(?,?,?,?,?,?)",
        [
          sqlight.text(record.session),
          sqlight.text(record.kernel),
          sqlight.text(record.token),
          sqlight.text(record.run_dir),
          sqlight.text(record.cwd),
          sqlight.text(record.modules),
        ],
      )
    })
  })
}

fn record_decoder() -> decode.Decoder(Record) {
  use session <- decode.field(0, decode.string)
  use kernel <- decode.field(1, decode.string)
  use token <- decode.field(2, decode.string)
  use run_dir <- decode.field(3, decode.string)
  use cwd <- decode.field(4, decode.string)
  use modules <- decode.field(5, decode.string)
  use out_seq <- decode.field(6, decode.int)
  use owned <- decode.field(7, decode.string)
  decode.success(Record(
    session,
    kernel,
    token,
    run_dir,
    cwd,
    modules,
    out_seq,
    owned,
  ))
}

const columns = "session,kernel,token,run_dir,cwd,modules,out_seq,json_object('pid',pid,'pgid',pgid,'leader',leader,'groups',json(groups))"

/// The kernel a session last booted, if one is recorded.
pub fn find(storage: store.Store, session: String) -> Option(Record) {
  store.read(
    storage,
    "SELECT " <> columns <> " FROM kernel_links WHERE session=?",
    [sqlight.text(session)],
    record_decoder(),
  )
  |> result.unwrap([])
  |> list.first
  |> option.from_result
}

/// Every recorded kernel, oldest first: what a starting daemon reattaches.
pub fn all(storage: store.Store) -> List(Record) {
  store.read(
    storage,
    "SELECT " <> columns <> " FROM kernel_links ORDER BY rowid",
    [],
    record_decoder(),
  )
  |> result.unwrap([])
}

/// Forget whatever kernel the session had: its row, its outbox, and its
/// call ledger. Also how a deleted session's rows go.
pub fn forget_session(
  db: sqlight.Connection,
  session: String,
) -> Result(Nil, String) {
  let id = [sqlight.text(session)]
  use _ <- result.try(store.run(
    db,
    "DELETE FROM kernel_calls WHERE kernel IN (SELECT kernel FROM kernel_links WHERE session=?)",
    id,
  ))
  use _ <- result.try(store.run(
    db,
    "DELETE FROM kernel_outbox WHERE session=?",
    id,
  ))
  store.run(db, "DELETE FROM kernel_links WHERE session=?", id)
}

/// Forget one kernel: its row, its outbox, and its call ledger.
pub fn forget(storage: store.Store, record: Record) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(
        store.run(db, "DELETE FROM kernel_calls WHERE kernel=?", [
          sqlight.text(record.kernel),
        ]),
      )
      use _ <- result.try(
        store.run(db, "DELETE FROM kernel_outbox WHERE session=? AND kernel=?", [
          sqlight.text(record.session),
          sqlight.text(record.kernel),
        ]),
      )
      store.run(db, "DELETE FROM kernel_links WHERE session=? AND kernel=?", [
        sqlight.text(record.session),
        sqlight.text(record.kernel),
      ])
    })
  })
}

/// The callbacks for one recorded kernel.
pub fn bind(storage: store.Store, record: Record) -> Link {
  Link(
    persist: fn(seq, frame) { log(persist(storage, record, seq, frame)) },
    ack: fn(upto) { log(ack(storage, record, upto)) },
    pending: fn() { pending(storage, record) },
    call: fn(id) { call(storage, record, id) },
    reply: fn(id, seq, frame) { log(reply(storage, record, id, seq, frame)) },
    record: fn(fields) { log(identify(storage, record, fields)) },
    forget: fn() { log(forget(storage, record)) },
    own: fn(groups) { log(own(storage, record, groups)) },
  )
}

/// The job groups the kernel owns now, by job id.
fn own(
  storage: store.Store,
  record: Record,
  groups: String,
) -> Result(Nil, String) {
  store.write(storage, "UPDATE kernel_links SET groups=? WHERE kernel=?", [
    sqlight.text(groups),
    sqlight.text(record.kernel),
  ])
}

fn log(outcome: Result(Nil, String)) -> Nil {
  case outcome {
    Ok(_) -> Nil
    Error(reason) -> io.println_error("kernel link: " <> reason)
  }
}

fn insert(
  db: sqlight.Connection,
  record: Record,
  seq: Int,
  frame: String,
) -> Result(Nil, String) {
  let kernel = [sqlight.text(record.session), sqlight.text(record.kernel)]
  use _ <- result.try(store.run(
    db,
    // A kernel already forgotten (its session deleted while the close was
    // still saying goodbye) gets no outbox back.
    "INSERT OR REPLACE INTO kernel_outbox(session,kernel,seq,frame)
      SELECT ?1,?2,?3,?4 WHERE EXISTS
        (SELECT 1 FROM kernel_links WHERE session=?1 AND kernel=?2)",
    list.append(kernel, [sqlight.int(seq), sqlight.text(frame)]),
  ))
  use _ <- result.try(
    store.run(
      db,
      "UPDATE kernel_links SET out_seq=max(out_seq,?) WHERE kernel=?",
      [sqlight.int(seq), sqlight.text(record.kernel)],
    ),
  )
  store.run(
    db,
    "DELETE FROM kernel_outbox WHERE session=?1 AND kernel=?2 AND seq IN (
      SELECT seq FROM (SELECT seq,
        SUM(length(frame)) OVER (ORDER BY seq DESC) AS total,
        ROW_NUMBER() OVER (ORDER BY seq DESC) AS n
        FROM kernel_outbox WHERE session=?1 AND kernel=?2)
      WHERE n > ?3 OR (n > 1 AND total > ?4))",
    list.append(kernel, [sqlight.int(outbox_frames), sqlight.int(outbox_bytes)]),
  )
}

pub fn persist(
  storage: store.Store,
  record: Record,
  seq: Int,
  frame: String,
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() { insert(db, record, seq, frame) })
  })
}

/// The kernel has every frame up to `upto`; so the calls those replies
/// answered can never be replayed again either.
pub fn ack(
  storage: store.Store,
  record: Record,
  upto: Int,
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(
        store.run(
          db,
          "DELETE FROM kernel_outbox WHERE session=? AND kernel=? AND seq<=?",
          [
            sqlight.text(record.session),
            sqlight.text(record.kernel),
            sqlight.int(upto),
          ],
        ),
      )
      store.run(db, "DELETE FROM kernel_calls WHERE kernel=? AND reply_seq<=?", [
        sqlight.text(record.kernel),
        sqlight.int(upto),
      ])
    })
  })
}

/// Unacknowledged frames, oldest first.
pub fn pending(storage: store.Store, record: Record) -> List(#(Int, String)) {
  store.read(
    storage,
    "SELECT seq,CAST(frame AS TEXT) FROM kernel_outbox WHERE session=? AND kernel=? ORDER BY seq",
    [sqlight.text(record.session), sqlight.text(record.kernel)],
    {
      use seq <- decode.field(0, decode.int)
      use frame <- decode.field(1, decode.string)
      decode.success(#(seq, frame))
    },
  )
  |> result.unwrap([])
}

/// Claim a host call id. The first claim runs the call; a later one finds
/// its reply on the way, or an earlier daemon's unanswered start. A call
/// still running in this daemon never reaches here: the port owner keeps
/// those in memory.
pub fn call(storage: store.Store, record: Record, id: String) -> CallState {
  let claimed =
    store.read(
      storage,
      "INSERT INTO kernel_calls(kernel,call) VALUES(?,?) ON CONFLICT DO NOTHING RETURNING call",
      [sqlight.text(record.kernel), sqlight.text(id)],
      decode.dynamic,
    )
  case claimed {
    Ok([_]) -> Fresh
    Error(_) -> Fresh
    Ok(_) ->
      case
        store.read(
          storage,
          "SELECT reply_seq FROM kernel_calls WHERE kernel=? AND call=?",
          [sqlight.text(record.kernel), sqlight.text(id)],
          decode.field(0, decode.optional(decode.int), decode.success),
        )
      {
        Ok([option.Some(_)]) -> Answered
        _ -> Unknown
      }
  }
}

/// Persist a call's reply frame and mark the call answered, together.
pub fn reply(
  storage: store.Store,
  record: Record,
  id: String,
  seq: Int,
  frame: String,
) -> Result(Nil, String) {
  store.query(storage, fn(db) {
    store.transaction(db, fn() {
      use _ <- result.try(insert(db, record, seq, frame))
      store.run(
        db,
        "INSERT INTO kernel_calls(kernel,call,reply_seq) VALUES(?,?,?) ON CONFLICT(kernel,call) DO UPDATE SET reply_seq=excluded.reply_seq",
        [sqlight.text(record.kernel), sqlight.text(id), sqlight.int(seq)],
      )
    })
  })
}

/// What the kernel's hello said about itself: process identity and epoch.
fn identify(
  storage: store.Store,
  record: Record,
  fields: String,
) -> Result(Nil, String) {
  let decoder = {
    use pid <- decode.optional_field(
      "pid",
      option.None,
      decode.optional(decode.int),
    )
    use pgid <- decode.optional_field(
      "pgid",
      option.None,
      decode.optional(decode.int),
    )
    use leader <- decode.optional_field(
      "leader",
      option.None,
      decode.optional(decode.string),
    )
    use epoch <- decode.optional_field("epoch", 0, decode.int)
    decode.success(#(pid, pgid, leader, epoch))
  }
  use #(pid, pgid, leader, epoch) <- result.try(
    json.parse(fields, decoder)
    |> result.replace_error("invalid kernel identity"),
  )
  store.write(
    storage,
    "UPDATE kernel_links SET pid=?,pgid=?,leader=?,epoch=? WHERE kernel=?",
    [
      sqlight.nullable(sqlight.int, pid),
      sqlight.nullable(sqlight.int, pgid),
      sqlight.nullable(sqlight.text, leader),
      sqlight.int(epoch),
      sqlight.text(record.kernel),
    ],
  )
}
