import albedo/daemon/conversation
import albedo/daemon/store
import albedo/harness/command.{Data, ModelCall, UserCall}
import albedo/harness/extensions/webhooks/command as webhook_command
import albedo/harness/extensions/webhooks/ledger as webhooks
import albedo/harness/extensions/webhooks/rpc as webhook_rpc
import albedo/openai_api/types
import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import sqlight

@external(erlang, "albedo_webhooks_test_support", "sign")
fn sign(body: BitArray, secret: String) -> String

fn headers(signature: String) -> List(#(String, String)) {
  [#("x-albedo-signature", signature)]
}

fn database() -> store.Store {
  let assert Ok(db) =
    store.start(
      ":memory:",
      "PRAGMA foreign_keys=ON; CREATE TABLE sessions(id TEXT PRIMARY KEY); INSERT INTO sessions VALUES('infra'),('other');",
    )
  let assert Ok(Nil) = webhooks.initialise(db)
  db
}

pub fn management_page_and_agent_route_enforce_opt_in_test() {
  let db = database()
  let cmd = webhook_command.command(db, "infra")
  let context =
    command.Context(fn(_) {
      panic as "webhook management must not submit a turn"
    })
  let args = dict.from_list([#("action", "create"), #("details", "deploy")])
  let assert Ok(Data(_)) =
    command.call([cmd], context, UserCall, "cli", "/webhooks", args, "")
  let denied =
    webhook_rpc.handle(
      db,
      "infra",
      "{\"method\":\"webhooks.list\",\"args\":{}}",
    )
  string.contains(denied, "denied") |> should.equal(True)
  let assert Ok(Data(_)) =
    command.call(
      [cmd],
      context,
      UserCall,
      "cli",
      "/webhooks",
      dict.from_list([#("action", "agent_on")]),
      "",
    )
  let listed =
    webhook_rpc.handle(
      db,
      "infra",
      "{\"method\":\"webhooks.list\",\"args\":{}}",
    )
  string.contains(listed, "deploy") |> should.equal(True)
  let other =
    webhook_rpc.handle(
      db,
      "other",
      "{\"method\":\"webhooks.list\",\"args\":{}}",
    )
  string.contains(other, "denied") |> should.equal(True)
  let assert Ok(Data(_)) =
    command.call(
      [cmd],
      context,
      ModelCall,
      "kernel",
      "/webhooks",
      dict.from_list([#("action", "create"), #("details", "alerts")]),
      "",
    )
  webhooks.list(db, webhooks.Human, "infra") |> should.be_ok
  store.close(db)
}

pub fn hooks_are_scoped_and_agent_access_is_opt_in_test() {
  let db = database()
  webhooks.list(db, webhooks.Agent("infra"), "infra")
  |> should.equal(Error(webhooks.Denied))
  webhooks.create(db, webhooks.Agent("infra"), "infra", "outage", None)
  |> should.equal(Error(webhooks.Denied))
  let assert Ok(webhooks.Provisioned(hook, secret)) =
    webhooks.create(db, webhooks.Human, "infra", "outage", None)
  secret |> should.not_equal("")
  let assert Ok([listed]) = webhooks.list(db, webhooks.Human, "infra")
  listed |> should.equal(hook)
  let assert Ok([]) = webhooks.list(db, webhooks.Human, "other")
  webhooks.agent_management(db, "infra") |> should.equal(Ok(False))
  webhooks.allow_agent(db, "infra", True) |> should.equal(Ok(Nil))
  let assert Ok([same]) = webhooks.list(db, webhooks.Agent("infra"), "infra")
  same |> should.equal(hook)
  webhooks.list(db, webhooks.Agent("infra"), "other")
  |> should.equal(Error(webhooks.Denied))
  webhooks.set_enabled(db, webhooks.Agent("other"), "infra", hook.id, 1, False)
  |> should.equal(Error(webhooks.Denied))
  webhooks.allow_agent(db, "infra", False) |> should.equal(Ok(Nil))
  webhooks.list(db, webhooks.Agent("infra"), "infra")
  |> should.equal(Error(webhooks.Denied))
  webhooks.list(db, webhooks.Human, "infra") |> should.equal(Ok([hook]))
  store.close(db)
}

pub fn signed_intake_and_atomic_session_receipt_test() {
  let assert Ok(db) = store.start(":memory:", "PRAGMA foreign_keys=ON;")
  let assert Ok(_) = conversation.initialise(db)
  let assert Ok(_) = webhooks.initialise(db)
  let assert Ok(_) =
    conversation.create(
      db,
      conversation.Info(
        "infra",
        "infra",
        "/tmp",
        "",
        "model",
        types.Responses,
        conversation.Idle,
        None,
        None,
      ),
    )
  let assert Ok(webhooks.Provisioned(hook, key)) =
    webhooks.create(db, webhooks.Human, "infra", "outage", None)
  let body = bit_array.from_string("{\"status\":\"down\"}")
  webhooks.accept(db, hook.id, headers("sha256=bad"), body, None)
  |> should.equal(Error(webhooks.Unauthorized))
  webhooks.accept(
    db,
    hook.id,
    headers(sign(body, key)),
    bit_array.from_string("changed"),
    None,
  )
  |> should.equal(Error(webhooks.Unauthorized))
  webhooks.accept(db, hook.id, headers(sign(body, key)), body, Some("bad\nkey"))
  |> should.be_error
  let assert Ok(delivery) =
    webhooks.accept(
      db,
      hook.id,
      headers(sign(body, key)),
      body,
      Some("alert-1"),
    )
  webhooks.accept(db, hook.id, headers(sign(body, key)), body, Some("alert-1"))
  |> should.equal(Ok(delivery))
  let changed = bit_array.from_string("different body")
  webhooks.accept(
    db,
    hook.id,
    headers(sign(changed, key)),
    changed,
    Some("alert-1"),
  )
  |> should.equal(Error(webhooks.Conflict))
  let assert Ok([pending]) = webhooks.pending(db, 10)
  pending.id |> should.equal(delivery)
  let assert Ok(_) =
    webhooks.delete(db, webhooks.Human, "infra", hook.id, hook.revision)
  webhooks.pending(db, 10) |> should.equal(Ok([pending]))
  pending.body |> should.equal(body)
  let message = types.User("webhook outage")
  let assert Ok(_) =
    conversation.commit_webhook_from(
      db,
      "infra",
      [message],
      conversation.Model,
      None,
      delivery,
    )
  webhooks.pending(db, 10) |> should.equal(Ok([]))
  webhooks.accept(db, hook.id, headers(sign(body, key)), body, None)
  |> should.equal(Error(webhooks.NotFound))
  conversation.commit_webhook_from(
    db,
    "infra",
    [message],
    conversation.Model,
    None,
    delivery,
  )
  |> should.be_error
  let assert Ok(history) = conversation.load(db, "infra")
  history |> should.equal([message])
  store.close(db)
}

pub fn full_inbox_refuses_new_delivery_test() {
  let db = database()
  let assert Ok(webhooks.Provisioned(hook, key)) =
    webhooks.create(db, webhooks.Human, "infra", "outage", None)
  store.query(db, fn(connection) {
    sqlight.query(
      "WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM nums WHERE n<1000) INSERT INTO webhook_deliveries(id,hook,name,session,body,body_sha256) SELECT 'seed-'||n,?,'outage','infra',x'00','digest' FROM nums",
      connection,
      [sqlight.text(hook.id)],
      decode.dynamic,
    )
  })
  |> should.be_ok
  let body = bit_array.from_string("outage")
  webhooks.accept(db, hook.id, headers(sign(body, key)), body, None)
  |> should.equal(Error(webhooks.Overloaded))
  store.close(db)
}

pub fn revisions_validation_and_cascade_test() {
  let db = database()
  webhooks.create(db, webhooks.Human, "infra", "bad name", None)
  |> should.be_error
  webhooks.create(db, webhooks.Human, "infra", "é", None)
  |> should.be_error
  webhooks.create(db, webhooks.Human, "infra", "outage", Some("short"))
  |> should.be_error
  let assert Ok(webhooks.Provisioned(hook, secret)) =
    webhooks.create(
      db,
      webhooks.Human,
      "infra",
      "outage",
      Some("sixteen-byte-key!"),
    )
  secret |> should.equal("sixteen-byte-key!")
  webhooks.create(db, webhooks.Human, "infra", "outage", None)
  |> should.equal(Error(webhooks.Conflict))
  let assert Ok(webhooks.Provisioned(rotated, new_key)) =
    webhooks.rotate(db, webhooks.Human, "infra", hook.id, 1, None)
  new_key |> should.not_equal(secret)
  rotated.revision |> should.equal(2)
  webhooks.rotate(db, webhooks.Human, "infra", hook.id, 1, None)
  |> should.equal(Error(webhooks.Conflict))
  let assert Ok(off) =
    webhooks.set_enabled(db, webhooks.Human, "infra", hook.id, 2, False)
  off.revision |> should.equal(3)
  off.enabled |> should.equal(False)
  webhooks.delete(db, webhooks.Human, "infra", hook.id, 2)
  |> should.equal(Error(webhooks.Conflict))
  webhooks.delete(db, webhooks.Human, "other", hook.id, 2)
  |> should.equal(Error(webhooks.NotFound))
  let assert Ok(_) = webhooks.delete(db, webhooks.Human, "infra", hook.id, 3)
  webhooks.list(db, webhooks.Human, "infra") |> should.equal(Ok([]))
  store.query(db, fn(connection) {
    sqlight.exec("DELETE FROM sessions WHERE id='infra'", connection)
  })
  |> should.be_ok
  webhooks.list(db, webhooks.Human, "infra") |> should.equal(Ok([]))
  store.close(db)
}
