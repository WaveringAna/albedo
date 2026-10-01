# existing storage migrations

core implementations live under `src/albedo/daemon/migrations/`;
extension implementations live under their own `migrations/` directories and
contribute `MigrationPlugin` values. the host applies them, without importing
extension-specific migration modules.

## startup order

`runtime.start` installs the extension registry before `server.prepare_storage`.
for each installed extension, `extension.install` first calls its table
initialiser, then applies its contributed `SchemaMigration` callbacks on the
store-owned SQLite connection, in plugin order. work contributes `cwd.apply`;
paperclips contributes `title.apply`, `scope.apply`, and `reply.apply`. their ledgers create tables but do not run
upgrades themselves. all installed owners upgrade, even when disabled for
sessions; session selection and live reload never rerun migrations.

`server.prepare_storage` then runs before sessions start:

1. `conversation.initialise` creates the core tables, then calls
   `conversation_columns.apply`: the existing session columns first, transcript
   columns second. it then runs its existing domain-local session recovery
   (missing activity/title from transcript), then creates `sessions_activity`.
2. quota, mail, and family initialise their tables, unchanged.
3. `migrations.run(ledger, backup)` runs the core `image_store.run`, which first
   externalizes legacy transcript images, then converts image-table TEXT data
   to decoded BLOB. It then runs `transcript_classes.run` to classify old
   transcript rows. `runtime.migrate(host, backup)` then collects installed
   extensions' `DataMigration` callbacks in registry/plugin order and applies
   them with the same backup path. python contributes `cell_images.run`, which
   requires the core image and marker tables. callbacks report named row counts;
   the server logs nonzero extension results as `migration <name>: <n> rows`.
   a failed callback stops startup and prevents later migrations from running.
4. the existing best-effort filesystem credential migration runs; then provider
   assignment from legacy configuration runs, unchanged.

schema creation is still owned by each subsystem. `work/migrations/cwd.apply`
checks `PRAGMA table_info(work)`, adds the existing reserved `__albedo_legacy__`
cwd default when absent, then creates `work_cwd_id`;
`paperclips/migrations/title.apply` adds the existing non-null empty-default title
column, `paperclips/migrations/scope.apply` drops the now-unused workspace
index left from the cwd-scoped vent era, and
`paperclips/migrations/reply.apply` adds the non-null empty-default reply
column that makes a /paperclips answer durable. these upgrades run immediately
after their owner's table creation, so later extension initialisers can use
the upgraded schema. embedding hosts call
`runtime.migrate` after preparing core storage and before opening sessions.

## compatibility and interruption

- `conversation_columns.apply` adds nullable `transcript.row_class`, checked
  against `user`, `image_fit`, and `other`. Live writes set it in the same
  transaction as the payload; forks copy it with the retained prefix.
  `transcript_classes.run` classifies only NULL rows in 128-row transactions.
  An invalid payload fails the current batch and startup; completed batches
  survive interruption. The backfill neither rewrites payloads nor adds a
  migration marker. It runs after the image migration.
- `transcript_pending_class` indexes unclassified sequence IDs.
  `transcript_users` indexes `(session,seq)` for user and image-fit rows;
  `transcript_fits` indexes `(session,seq)` for image-fit rows alone. Completed
  databases have no pending entries, so subsequent startups do not decode
  transcript payloads for classification.
- the existing `migrations(name,applied_at)` table remains unchanged. the exact
  markers are `image_store` and `cell_images`, recorded with `unixepoch()`.
  transcript migration skips when its marker exists; cell migration skips when
  its marker exists, and does nothing without a cells table.
- TEXT-to-BLOB migration deliberately has no marker. it checks
  `typeof(data)='text'` on every run and converts pending rows, even when the
  `image_store` marker already exists. invalid legacy base64 fails without
  replacing that row.
- transcript and cell scans retain their original cursor order and 16-row pages;
  BLOB conversion retains its 16-row limit. each page uses the existing
  transaction helper. there is no new all-migrations transaction or transaction
  policy change. markers are written at the original completion points, and
  interrupted runs recheck remaining rows.
- core `backup.gleam` and python's cell migration preserve the two existing
  backup call patterns: transcript and BLOB migration check for an existing file before directory creation and
  `VACUUM INTO`, retaining the `image store backup failed: ` error prefix; cell
  migration ensures the directory first and copies on the first page containing
  inline images, outside its transaction. the server still supplies one shared
  `home/backups/albedo-before-image-store-<timestamp>.sqlite` path. no backup is
  overwritten and backup triggering is unchanged (the transcript candidate
  check can include tool outputs without inline images).
- live writes and transcript migration share `image_payloads.insert`, the
  unchanged decoded-BLOB insertion helper. image hashes, serialized formats,
  image validation, and legacy inline fallback reads are unchanged. the existing
  Erlang conversion and cell packing functions remain the FFI implementation.

## migration inventory

| previous implementation | current implementation |
| --- | --- |
| `conversation.initialise`: session/transcript `add_columns` | `migrations/conversation_columns.apply` |
| transcript row classification | `migrations/transcript_classes.run`, after core image upgrades |
| `images.migrate` / `migrate_legacy` / transcript pages | `migrations/image_store.run` / `migrate_legacy` / transcript pages |
| `images.migrate_blobs` / BLOB pages | `migrations/image_store.migrate_blobs` / BLOB pages |
| `images.backup_before_migration` | `migrations/backup.image_store` |
| `python/cells.migrate_images` / cell pages | `python/migrations/cell_images.run` / cell pages |
| `python/cells.backup_before_migration` | `python/migrations/cell_images.backup_before_migration` |
| `work/ledger.initialise`: cwd alteration and index | `work/migrations/cwd.apply`, contributed by work |
| `paperclips/ledger.initialise`: title addition | `paperclips/migrations/title.apply`, contributed by paperclips |
| `paperclips/ledger.initialise`: `paperclips_cwd` index creation | dropped from the schema; `paperclips/migrations/scope.apply` removes it from existing stores |
| `paperclips/ledger.initialise`: reply column | `paperclips/migrations/reply.apply`, added with the global ledger |

`images.migrate` and `cells.migrate_images` are removed rather than wrapped:
the migration implementations are separate from the live domain readers and
writers. startup discovers extension upgrades through plugins, not direct calls
to their implementation modules.

## intentionally not extracted

- session recovery stays in `conversation`: it uses the domain's transcript
  decoding/title helpers and still runs at exactly the same point. core schema
  bootstrap and index creation remain with their owners.
- rolling compaction's legacy item-count-to-user-cut conversion remains lazy in
  `rolling/extension.resume`. it needs the current prepared history and source,
  validates the old fingerprint (including legacy image payload fingerprints),
  and only writes a cut when the history matches and its tail begins with a user
  message. treating this as an unconditional startup migration would change its
  timing and semantics; its projections are untouched.
- credentials migration is filesystem/auth, not SQLite. legacy configuration's
  provider assignment likewise remains in the existing server startup path.
- no zstd, compression, schema-version, offline storage upgrade,
  new dependency, or unrelated transaction fix is part of this refactor.
