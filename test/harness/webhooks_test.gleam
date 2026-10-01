//// A full inbox must reject new webhook deliveries rather than silently lose mail.

import albedo/daemon/store
import albedo/harness/extensions/webhooks/ledger as webhooks
import gleam/bit_array
import gleam/dynamic/decode
import gleam/option.{None}
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

pub fn full_inbox_refuses_new_delivery_test() -> Nil {
  let db = database()
  let assert Ok(webhooks.Provisioned(hook, key)) =
    webhooks.create(db, webhooks.Human, "infra", "outage", None)
  store.query(db, fn(connection) {
    sqlight.query(
      "WITH RECURSIVE nums(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM nums WHERE n<1000) INSERT INTO mail(id,recipient,sender_name,kind,body,created_at) SELECT 'seed-'||n,'infra','outage','webhook','x',0 FROM nums",
      connection,
      [],
      decode.dynamic,
    )
  })
  |> should.be_ok
  let body = bit_array.from_string("outage")
  webhooks.accept(db, hook.id, headers(sign(body, key)), body, None)
  |> should.equal(Error(webhooks.Overloaded))
  // The refused delivery left no half behind.
  store.query(db, fn(connection) {
    sqlight.query(
      "SELECT count(*) FROM webhook_deliveries",
      connection,
      [],
      decode.field(0, decode.int, decode.success),
    )
  })
  |> should.equal(Ok([0]))
  store.close(db)
}
