# existing storage migrations

this is an organization of the migrations already shipped, not a new migration
framework or schema version. the implementations live under
`src/albedo/daemon/migrations/`; `src/albedo/daemon/migrations.gleam` is the
explicit ordered entrypoint for startup data upgrades.

## startup order

`server.prepare_storage` still runs before sessions start:

1. `conversation.initialise` creates the core tables, then calls
   `conversation_columns.apply`: the existing session columns first, transcript
   columns second. it then runs its existing domain-local session recovery
   (missing activity/title from transcript), then creates `sessions_activity`.
2. quota, mail, and family initialise their tables, unchanged.
3. `migrations.run(ledger, backup)` runs `image_store.run`, then
   `cell_images.run`, returning `#(transcript_rows_moved, cell_results_moved)`
   for the existing server log messages. `image_store.run` first externalizes
   legacy transcript images, then converts image-table TEXT data to decoded BLOB.
4. the existing best-effort filesystem credential migration runs; then provider
   assignment from legacy configuration runs, unchanged.

schema creation is still owned by each subsystem. work and paperclips upgrade
only when their extension initialisers run, not unconditionally at core startup:
`work_cwd.apply` checks `PRAGMA table_info(work)`, adds the existing reserved
`__albedo_legacy__` cwd default when absent, then creates `work_cwd_id`;
`paperclips_title.apply` adds the existing non-null empty-default title column.
these calls remain after each owner's table creation.

## compatibility and interruption

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
- `backup.gleam` preserves the two existing backup call patterns: transcript
  and BLOB migration check for an existing file before directory creation and
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
| `images.migrate` / `migrate_legacy` / transcript pages | `migrations/image_store.run` / `migrate_legacy` / transcript pages |
| `images.migrate_blobs` / BLOB pages | `migrations/image_store.migrate_blobs` / BLOB pages |
| `images.backup_before_migration` | `migrations/backup.image_store` |
| `python/cells.migrate_images` / cell pages | `migrations/cell_images.run` / cell pages |
| `python/cells.backup_before_migration` | `migrations/backup.cell_images` |
| `work/ledger.initialise`: cwd alteration and index | `migrations/work_cwd.apply` |
| `paperclips/ledger.initialise`: title addition | `migrations/paperclips_title.apply` |

`images.migrate` and `cells.migrate_images` are removed rather than wrapped:
wrappers would introduce import cycles between image/cell domain modules and
migration modules. direct callers use the migration modules instead.

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
- no zstd, compression, reference index, schema-version, offline storage upgrade,
  new dependency, or unrelated transaction fix is part of this refactor.
