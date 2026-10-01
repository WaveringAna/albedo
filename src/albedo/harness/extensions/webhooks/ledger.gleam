//// Durable hook definitions. All mutations run on the daemon store owner.

import albedo/daemon/mail
import albedo/daemon/store
import albedo/daemon/usage
import gleam/bit_array
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import sqlight

pub type Store =
  store.Store

pub type Actor {
  Human
  Agent(session: String)
}

pub type Hook {
  Hook(
    id: String,
    session: String,
    name: String,
    enabled: Bool,
    signature_header: String,
    signature_prefix: String,
    revision: Int,
  )
}

pub type Provisioned {
  Provisioned(hook: Hook, secret: String)
}

pub type Error {
  Invalid(String)
  Denied
  NotFound
  Conflict
  Unauthorized
  Overloaded
  Storage(String)
}

pub type Delivery {
  Delivery(
    id: String,
    hook: String,
    name: String,
    session: String,
    body: BitArray,
  )
}

const schema = "
CREATE TABLE IF NOT EXISTS webhook_permissions (
 session TEXT PRIMARY KEY REFERENCES sessions(id) ON DELETE CASCADE,
 agent_manage INTEGER NOT NULL DEFAULT 0 CHECK(agent_manage IN (0,1))
);
CREATE TABLE IF NOT EXISTS webhook_hooks (
 id TEXT PRIMARY KEY,
 session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 name TEXT NOT NULL,
 secret TEXT NOT NULL,
 enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
 signature_header TEXT NOT NULL DEFAULT 'x-albedo-signature',
 signature_prefix TEXT NOT NULL DEFAULT 'sha256=',
 revision INTEGER NOT NULL DEFAULT 1,
 UNIQUE(session,name)
);
CREATE INDEX IF NOT EXISTS webhook_hooks_session ON webhook_hooks(session);
CREATE TABLE IF NOT EXISTS webhook_deliveries (
 id TEXT PRIMARY KEY,
 hook TEXT NOT NULL,
 name TEXT NOT NULL,
 session TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
 body BLOB NOT NULL,
 body_sha256 TEXT NOT NULL,
 event_key TEXT,
 received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
 delivered_at TEXT,
 attempts INTEGER NOT NULL DEFAULT 0,
 last_error TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS webhook_event_key ON webhook_deliveries(hook,event_key) WHERE event_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS webhook_pending ON webhook_deliveries(received_at) WHERE delivered_at IS NULL;
"

pub fn initialise(db: store.Store) -> Result(Nil, String) {
  use _ <- result.try(mail.initialise(db))
  store.query(db, fn(connection) {
    use _ <- result.try(store.exec(connection, schema))
    move_inbox(connection)
  })
}

/// Deliveries accepted before the daemon's mail inbox existed waited in this
/// table; each becomes the letter it would have been. Later deliveries write
/// their letter in `accept`, so they are never missing one.
fn move_inbox(connection: sqlight.Connection) -> Result(Nil, String) {
  use waiting <- result.try(store.rows(
    connection,
    "SELECT id,hook,name,session,body FROM webhook_deliveries d WHERE delivered_at IS NULL AND NOT EXISTS(SELECT 1 FROM mail m WHERE m.id=d.id)",
    [],
    delivery_decoder(),
  ))
  list.try_each(waiting, fn(delivery) {
    mail.insert(connection, letter(delivery)) |> result.replace(Nil)
  })
}

/// A delivery as the letter its session reads: a bounded preview, with the
/// whole payload a `webhooks.delivery(id)` call away.
fn letter(delivery: Delivery) -> mail.Letter {
  let preview =
    delivery.body
    |> bit_array.to_string
    |> result.map(fn(text) { string.slice(text, 0, 4000) })
    |> result.unwrap("[binary payload; read the delivery by id]")
  mail.Letter(
    delivery.id,
    delivery.session,
    None,
    delivery.name,
    mail.Webhook,
    preview,
    usage.now(),
  )
}

const columns = "id,session,name,enabled,signature_header,signature_prefix,revision"

fn decoder() -> decode.Decoder(Hook) {
  use id <- decode.field(0, decode.string)
  use session <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use enabled <- decode.field(3, decode.int)
  use header <- decode.field(4, decode.string)
  use prefix <- decode.field(5, decode.string)
  use revision <- decode.field(6, decode.int)
  decode.success(Hook(id, session, name, enabled == 1, header, prefix, revision))
}

fn query(
  db: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
  row_decoder: decode.Decoder(a),
) -> Result(List(a), Error) {
  store.rows(db, sql, args, row_decoder) |> result.map_error(Storage)
}

fn exec(db: sqlight.Connection, sql: String) -> Result(Nil, Error) {
  store.exec(db, sql) |> result.map_error(Storage)
}

fn rows(
  db: sqlight.Connection,
  sql: String,
  args: List(sqlight.Value),
) -> Result(List(Hook), Error) {
  query(db, sql, args, decoder())
}

fn one(hooks: List(Hook)) -> Result(Hook, Error) {
  list.first(hooks) |> result.replace_error(NotFound)
}

fn one_or_conflict(hooks: List(a)) -> Result(a, Error) {
  list.first(hooks) |> result.replace_error(Conflict)
}

fn agent_manage(
  db: sqlight.Connection,
  session: String,
) -> Result(Bool, Error) {
  query(
    db,
    "SELECT agent_manage FROM webhook_permissions WHERE session=?",
    [sqlight.text(session)],
    decode.field(0, decode.int, decode.success),
  )
  |> result.map(fn(rows) { rows == [1] })
}

fn permitted(
  db: sqlight.Connection,
  actor: Actor,
  session: String,
) -> Result(Nil, Error) {
  case actor {
    Human -> Ok(Nil)
    Agent(owner) if owner != session -> Error(Denied)
    Agent(_) -> {
      use allowed <- result.try(agent_manage(db, session))
      case allowed {
        True -> Ok(Nil)
        False -> Error(Denied)
      }
    }
  }
}

pub fn agent_management(
  db: store.Store,
  session: String,
) -> Result(Bool, Error) {
  store.query(db, agent_manage(_, session))
}

/// Only the human-facing management path may grant agent self-management.
pub fn allow_agent(
  db: store.Store,
  session: String,
  enabled: Bool,
) -> Result(Nil, Error) {
  store.query(db, fn(connection) {
    store.run(
      connection,
      "INSERT INTO webhook_permissions(session,agent_manage) VALUES(?,?) ON CONFLICT(session) DO UPDATE SET agent_manage=excluded.agent_manage",
      [sqlight.text(session), sqlight.bool(enabled)],
    )
    |> result.map_error(Storage)
  })
}

/// The page shows whether a hook has accepted work still awaiting the session.
pub fn last_failure(
  db: store.Store,
  session: String,
  id: String,
) -> Result(Option(String), Error) {
  store.query(db, fn(connection) {
    query(
      connection,
      "SELECT m.last_error FROM webhook_deliveries d JOIN mail m ON m.id=d.id WHERE d.session=? AND d.hook=? AND m.delivered_at IS NULL AND m.last_error IS NOT NULL ORDER BY m.created_at DESC,m.id DESC LIMIT 1",
      [sqlight.text(session), sqlight.text(id)],
      decode.field(0, decode.string, decode.success),
    )
    |> result.map(fn(errors) { list.first(errors) |> option.from_result })
  })
}

pub fn pending_count(
  db: store.Store,
  session: String,
  id: String,
) -> Result(Int, Error) {
  store.query(db, fn(connection) {
    query(
      connection,
      "SELECT count(*) FROM webhook_deliveries d JOIN mail m ON m.id=d.id WHERE d.session=? AND d.hook=? AND m.delivered_at IS NULL",
      [sqlight.text(session), sqlight.text(id)],
      decode.field(0, decode.int, decode.success),
    )
    |> result.map(fn(counts) { list.first(counts) |> result.unwrap(0) })
  })
}

pub fn list(
  db: store.Store,
  actor: Actor,
  session: String,
) -> Result(List(Hook), Error) {
  store.query(db, fn(connection) {
    use _ <- result.try(permitted(connection, actor, session))
    rows(
      connection,
      "SELECT "
        <> columns
        <> " FROM webhook_hooks WHERE session=? ORDER BY name LIMIT 100",
      [sqlight.text(session)],
    )
  })
}

/// Every session's hooks, for the human's Webhooks screen.
pub fn list_all(db: store.Store) -> Result(List(Hook), Error) {
  store.query(
    db,
    rows(
      _,
      "SELECT " <> columns <> " FROM webhook_hooks ORDER BY session,name",
      [],
    ),
  )
}

/// A hook by id in whichever session it targets. Only the human path uses
/// this; the agent's lookups stay scoped to its own session.
pub fn find(db: store.Store, id: String) -> Result(Hook, Error) {
  store.query(
    db,
    rows(_, "SELECT " <> columns <> " FROM webhook_hooks WHERE id=?", [
      sqlight.text(id),
    ]),
  )
  |> result.try(one)
}

fn find_owned(
  db: sqlight.Connection,
  actor: Actor,
  session: String,
  id: String,
) -> Result(Hook, Error) {
  use _ <- result.try(permitted(db, actor, session))
  rows(
    db,
    "SELECT " <> columns <> " FROM webhook_hooks WHERE id=? AND session=?",
    [sqlight.text(id), sqlight.text(session)],
  )
  |> result.try(one)
}

fn mutate_owned(
  db: store.Store,
  actor: Actor,
  session: String,
  id: String,
  sql: String,
  args: List(sqlight.Value),
) -> Result(Hook, Error) {
  store.query(db, fn(connection) {
    use _ <- result.try(find_owned(connection, actor, session, id))
    use changed <- result.try(rows(connection, sql, args))
    one_or_conflict(changed)
  })
}

pub fn get(
  db: store.Store,
  actor: Actor,
  session: String,
  id: String,
) -> Result(Hook, Error) {
  store.query(db, find_owned(_, actor, session, id))
}

pub fn to_json(hook: Hook) -> json.Json {
  json.object([
    #("id", json.string(hook.id)),
    #("session", json.string(hook.session)),
    #("name", json.string(hook.name)),
    #("enabled", json.bool(hook.enabled)),
    #("url", json.string("/webhooks/" <> hook.id)),
    #("signatureHeader", json.string(hook.signature_header)),
    #("signaturePrefix", json.string(hook.signature_prefix)),
    #("revision", json.int(hook.revision)),
  ])
}

pub fn create(
  db: store.Store,
  actor: Actor,
  session: String,
  name: String,
  supplied_secret: Option(String),
) -> Result(Provisioned, Error) {
  use _ <- result.try(validate_name(name))
  use secret <- result.try(secret_value(supplied_secret))
  store.query(db, fn(connection) {
    use _ <- result.try(permitted(connection, actor, session))
    use existing <- result.try(
      rows(
        connection,
        "SELECT " <> columns <> " FROM webhook_hooks WHERE session=? AND name=?",
        [sqlight.text(session), sqlight.text(name)],
      ),
    )
    case existing {
      [_, ..] -> Error(Conflict)
      [] ->
        rows(
          connection,
          "INSERT INTO webhook_hooks(id,session,name,secret) SELECT ?,?,?,? WHERE (SELECT count(*) FROM webhook_hooks WHERE session=?) < 32 RETURNING "
            <> columns,
          [
            sqlight.text(new_id()),
            sqlight.text(session),
            sqlight.text(name),
            sqlight.text(secret),
            sqlight.text(session),
          ],
        )
        |> result.try(one_or_conflict)
        |> result.map(Provisioned(_, secret))
    }
  })
}

/// Rotation replaces the signing key at the expected revision and returns it once.
pub fn rotate(
  db: store.Store,
  actor: Actor,
  session: String,
  id: String,
  revision: Int,
  supplied_secret: Option(String),
) -> Result(Provisioned, Error) {
  use secret <- result.try(secret_value(supplied_secret))
  mutate_owned(
    db,
    actor,
    session,
    id,
    "UPDATE webhook_hooks SET secret=?,revision=revision+1 WHERE id=? AND session=? AND revision=? RETURNING "
      <> columns,
    [
      sqlight.text(secret),
      sqlight.text(id),
      sqlight.text(session),
      sqlight.int(revision),
    ],
  )
  |> result.map(Provisioned(_, secret))
}

fn secret_value(supplied: Option(String)) -> Result(String, Error) {
  case supplied {
    None -> Ok(new_secret())
    Some(secret) ->
      case string.byte_size(secret) >= 16 && string.byte_size(secret) <= 4096 {
        True -> Ok(secret)
        False -> Error(Invalid("secret must be 16–4096 bytes"))
      }
  }
}

pub fn configure(
  db: store.Store,
  actor: Actor,
  session: String,
  id: String,
  revision: Int,
  header: String,
  prefix: String,
) -> Result(Hook, Error) {
  use _ <- result.try(validate_header(header))
  use _ <- result.try(validate_prefix(prefix))
  mutate_owned(
    db,
    actor,
    session,
    id,
    "UPDATE webhook_hooks SET signature_header=?,signature_prefix=?,revision=revision+1 WHERE id=? AND session=? AND revision=? RETURNING "
      <> columns,
    [
      sqlight.text(string.lowercase(header)),
      sqlight.text(prefix),
      sqlight.text(id),
      sqlight.text(session),
      sqlight.int(revision),
    ],
  )
}

fn ascii_charset(text: String, allowed: String) -> Bool {
  text
  |> string.to_graphemes
  |> list.all(string.contains(allowed, _))
}

fn validate_ascii(
  text: String,
  allowed: String,
  error: String,
) -> Result(Nil, Error) {
  case
    string.byte_size(text) > 0
    && string.byte_size(text) <= 64
    && ascii_charset(text, allowed)
  {
    True -> Ok(Nil)
    False -> Error(Invalid(error))
  }
}

fn validate_header(header: String) -> Result(Nil, Error) {
  validate_ascii(
    header,
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-",
    "signature header must be 1–64 ASCII letters, digits or -",
  )
}

fn validate_prefix(prefix: String) -> Result(Nil, Error) {
  case
    string.byte_size(prefix) <= 32
    && !string.contains(prefix, "\r")
    && !string.contains(prefix, "\n")
  {
    True -> Ok(Nil)
    False ->
      Error(Invalid(
        "signature prefix must be at most 32 bytes with no newlines",
      ))
  }
}

pub fn set_enabled(
  db: store.Store,
  actor: Actor,
  session: String,
  id: String,
  revision: Int,
  enabled: Bool,
) -> Result(Hook, Error) {
  mutate_owned(
    db,
    actor,
    session,
    id,
    "UPDATE webhook_hooks SET enabled=?,revision=revision+1 WHERE id=? AND session=? AND revision=? RETURNING "
      <> columns,
    [
      sqlight.bool(enabled),
      sqlight.text(id),
      sqlight.text(session),
      sqlight.int(revision),
    ],
  )
}

pub fn delete(
  db: store.Store,
  actor: Actor,
  session: String,
  id: String,
  revision: Int,
) -> Result(Hook, Error) {
  mutate_owned(
    db,
    actor,
    session,
    id,
    "DELETE FROM webhook_hooks WHERE id=? AND session=? AND revision=? RETURNING "
      <> columns,
    [sqlight.text(id), sqlight.text(session), sqlight.int(revision)],
  )
}

/// Ingress and enqueue are one serialized store operation. Never return a signing
/// key to the HTTP handler, and never acknowledge a delivery before its insert.
pub fn accept(
  db: store.Store,
  id: String,
  headers: List(#(String, String)),
  body: BitArray,
  event_key: Option(String),
) -> Result(String, Error) {
  case bit_array.byte_size(body) > 65_536, invalid_event_key(event_key) {
    True, _ -> Error(Invalid("webhook body exceeds 64 KiB"))
    _, True -> Error(Invalid("event id must be 1–128 bytes with no newlines"))
    False, False ->
      store.query(db, fn(connection) {
        let cred_decoder = {
          use session <- decode.field(0, decode.string)
          use name <- decode.field(1, decode.string)
          use secret <- decode.field(2, decode.string)
          use header <- decode.field(3, decode.string)
          use prefix <- decode.field(4, decode.string)
          decode.success(#(session, name, secret, header, prefix))
        }
        use credentials <- result.try(query(
          connection,
          "SELECT session,name,secret,signature_header,signature_prefix FROM webhook_hooks WHERE id=? AND enabled=1",
          [sqlight.text(id)],
          cred_decoder,
        ))
        use #(session, name, secret, header, prefix) <- result.try(
          list.first(credentials) |> result.replace_error(NotFound),
        )
        let signature = list.key_find(headers, header) |> result.unwrap("")
        case verify(body, signature, secret, prefix) {
          False -> Error(Unauthorized)
          True -> {
            let delivery_id = new_id()
            let digest = fingerprint(body)
            use inserted <- result.try(enqueue(
              connection,
              Delivery(delivery_id, id, name, session, body),
              digest,
              event_key,
            ))
            case inserted {
              [delivery_id, ..] -> Ok(delivery_id)
              [] ->
                case event_key {
                  None -> Error(Overloaded)
                  Some(key) -> {
                    let decoder = {
                      use existing_id <- decode.field(0, decode.string)
                      use existing_digest <- decode.field(1, decode.string)
                      decode.success(#(existing_id, existing_digest))
                    }
                    use found <- result.try(query(
                      connection,
                      "SELECT id,body_sha256 FROM webhook_deliveries WHERE hook=? AND event_key=?",
                      [sqlight.text(id), sqlight.text(key)],
                      decoder,
                    ))
                    case found {
                      [#(existing, saved), ..] if saved == digest -> Ok(existing)
                      [_, ..] -> Error(Conflict)
                      [] -> Error(Overloaded)
                    }
                  }
                }
            }
          }
        }
      })
  }
}

/// The delivery and its letter, or neither: a full inbox or a repeated event
/// id writes nothing and answers no rows.
fn enqueue(
  connection: sqlight.Connection,
  delivery: Delivery,
  digest: String,
  event_key: Option(String),
) -> Result(List(String), Error) {
  use _ <- result.try(exec(connection, "SAVEPOINT webhook_accept"))
  let written = {
    use inserted <- result.try(query(
      connection,
      "INSERT INTO webhook_deliveries(id,hook,name,session,body,body_sha256,event_key) VALUES(?,?,?,?,?,?,?) ON CONFLICT DO NOTHING RETURNING id",
      [
        sqlight.text(delivery.id),
        sqlight.text(delivery.hook),
        sqlight.text(delivery.name),
        sqlight.text(delivery.session),
        sqlight.blob(delivery.body),
        sqlight.text(digest),
        sqlight.nullable(sqlight.text, event_key),
      ],
      decode.field(0, decode.string, decode.success),
    ))
    case inserted {
      [] -> Ok([])
      _ ->
        case mail.insert(connection, letter(delivery)) {
          Ok(True) -> Ok(inserted)
          Ok(False) -> Error(Overloaded)
          Error(message) -> Error(Storage(message))
        }
    }
  }
  case written {
    Ok(rows) ->
      exec(connection, "RELEASE webhook_accept")
      |> result.replace(rows)
    Error(error) -> {
      let _ = store.exec(connection, "ROLLBACK TO webhook_accept")
      let _ = store.exec(connection, "RELEASE webhook_accept")
      Error(error)
    }
  }
}

fn invalid_event_key(key: Option(String)) -> Bool {
  case key {
    None -> False
    Some(value) ->
      string.byte_size(value) == 0
      || string.byte_size(value) > 128
      || string.contains(value, "\r")
      || string.contains(value, "\n")
  }
}

fn delivery_decoder() -> decode.Decoder(Delivery) {
  use id <- decode.field(0, decode.string)
  use hook <- decode.field(1, decode.string)
  use name <- decode.field(2, decode.string)
  use session <- decode.field(3, decode.string)
  use body <- decode.field(4, decode.bit_array)
  decode.success(Delivery(id, hook, name, session, body))
}

/// Reading an accepted payload is not a management operation. The target
/// session owns its inbox whether or not agent provisioning is enabled.
pub fn delivery(
  db: store.Store,
  session: String,
  id: String,
) -> Result(Delivery, Error) {
  store.query(db, fn(connection) {
    query(
      connection,
      "SELECT id,hook,name,session,body FROM webhook_deliveries WHERE id=? AND session=?",
      [sqlight.text(id), sqlight.text(session)],
      delivery_decoder(),
    )
    |> result.try(fn(rows) {
      list.first(rows) |> result.replace_error(NotFound)
    })
  })
}

fn validate_name(name: String) -> Result(Nil, Error) {
  validate_ascii(
    name,
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-",
    "name must contain 1–64 ASCII letters, digits, _ or -",
  )
}

@external(erlang, "albedo_webhooks", "fingerprint")
fn fingerprint(body: BitArray) -> String

@external(erlang, "albedo_webhooks", "verify")
fn verify(
  body: BitArray,
  signature: String,
  secret: String,
  prefix: String,
) -> Bool

@external(erlang, "albedo_webhooks", "new_id")
fn new_id() -> String

@external(erlang, "albedo_webhooks", "new_secret")
fn new_secret() -> String
