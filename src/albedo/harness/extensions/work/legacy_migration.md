# Recovering legacy work items

The workspace-scoped ledger keeps rows created by older versions under the reserved
`__albedo_legacy__` scope. No workspace sees these rows automatically: the old
schema did not record which workspace owned them.

1. Stop Albedo and back up `$ALBEDO_HOME/albedo.sqlite` before editing it. For
   example, use `sqlite3 "$ALBEDO_HOME/albedo.sqlite" ".backup '/safe/path/work.sqlite'"`.
2. Inspect the old items and their parent relationships:

   ```sql
   SELECT id, title, parent FROM work WHERE cwd = '__albedo_legacy__';
   ```

3. Choose an existing workspace's **absolute canonical path**. Move only items
   you can attribute to it; move parents and children together. In SQLite,
   verify the IDs and the destination before committing:

   ```sql
   BEGIN IMMEDIATE;
   UPDATE work SET cwd = '/absolute/workspace' WHERE id IN (12, 13);
   SELECT id, cwd, parent FROM work WHERE id IN (12, 13);
   COMMIT;
   ```

4. Restart Albedo and use `/work` in that workspace to verify visibility.
   Restore the backup if the mapping was wrong. Leave uncertain rows in the
   legacy scope; never assign every old row to every workspace.

Startup adds the `cwd` column before creating its index on an older database;
restarting alone does not reassign legacy items.
