//// The built-in daemon cannot install arbitrary test extensions. Probe the
//// cross-extension contract here: schema-before-use, deferred data, order,
//// backup propagation, disabled-but-installed owners, and failure short-circuit.

import albedo/daemon/store
import albedo/harness/extension
import gleam/dynamic/decode
import gleam/result
import gleeunit/should
import sqlight

pub fn contributed_migrations_keep_their_phases_and_stop_on_failure_test() {
  let assert Ok(ledger) = store.start(":memory:", "")
  let installed = [
    extension.Extension(
      "owner",
      "",
      [],
      [
        extension.MigrationPlugin(
          extension.SchemaMigration(fn(db) {
            store.add_columns(db, "owner", [#("revision", "INTEGER DEFAULT 1")])
          }),
        ),
        extension.MigrationPlugin(
          extension.DataMigration("owner-data", fn(ledger, backup) {
            use _ <- result.try(store.read(
              ledger,
              "SELECT 1 FROM core_ready",
              [],
              decode.dynamic,
            ))
            store.write(
              ledger,
              "INSERT INTO applied(name,backup) VALUES('owner',?)",
              [sqlight.text(backup)],
            )
            |> result.replace(1)
          }),
        ),
      ],
      fn(ledger) {
        store.query(ledger, store.exec(
          _,
          "CREATE TABLE owner(id INTEGER); CREATE TABLE applied(name TEXT,backup TEXT)",
        ))
      },
    ),
    extension.Extension(
      "sibling",
      "",
      [],
      [
        extension.MigrationPlugin(
          extension.DataMigration("sibling-data", fn(ledger, backup) {
            store.write(
              ledger,
              "INSERT INTO applied(name,backup) VALUES('sibling',?)",
              [sqlight.text(backup)],
            )
            |> result.replace(1)
          }),
        ),
      ],
      fn(ledger) {
        // This initialiser depends on the previous owner's schema upgrade.
        store.write(ledger, "INSERT INTO owner(revision) VALUES(2)", [])
      },
    ),
  ]
  // Neither extension is enabled for sessions, but both own durable tables.
  let assert Ok(#(_, [])) = extension.install(installed, [], ledger)
  let assert Ok([2]) =
    store.read(
      ledger,
      "SELECT revision FROM owner",
      [],
      decode.field(0, decode.int, decode.success),
    )
  let assert Ok([]) =
    store.read(ledger, "SELECT * FROM applied", [], decode.dynamic)
  let assert Error(_) = extension.migrate(installed, ledger, "/backup")
  let assert Ok([]) =
    store.read(ledger, "SELECT * FROM applied", [], decode.dynamic)
  let assert Ok(_) =
    store.query(ledger, store.exec(_, "CREATE TABLE core_ready(id INTEGER)"))
  extension.migrate(installed, ledger, "/backup")
  |> should.equal(Ok([#("owner-data", 1), #("sibling-data", 1)]))
  let assert Ok(rows) =
    store.read(ledger, "SELECT name,backup FROM applied ORDER BY rowid", [], {
      use name <- decode.field(0, decode.string)
      use backup <- decode.field(1, decode.string)
      decode.success(#(name, backup))
    })
  rows |> should.equal([#("owner", "/backup"), #("sibling", "/backup")])
  store.close(ledger)
}
