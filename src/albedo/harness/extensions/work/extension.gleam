import albedo/daemon/store
import albedo/harness/client_api
import albedo/harness/command.{Argument}
import albedo/harness/extension as harness_extension
import albedo/harness/extensions/work/ledger as work
import albedo/harness/extensions/work/migrations/cwd
import albedo/harness/extensions/work/rpc
import gleam/http
import gleam/json
import gleam/option.{Some}

import albedo/harness/extensions/work/service

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "work",
    "A durable revision-checked work ledger shared by humans and agents.",
    ["python"],
    [
      harness_extension.CommandPlugin([
        command.resource(
          "/work",
          "Show the shared work ledger, or change it: add <title>, edit <id> <title>, status <id> <status>, remove <id>. The agent is told about every change.",
          [
            Argument(
              "action",
              "what to change; omit to list the ledger",
              False,
              ["add", "edit", "status", "remove"],
            ),
            Argument(
              "details",
              "add: <title> · edit: <id> <title> · status: <id> <open|active|blocked|done|cancelled> · remove: <id>",
              False,
              [],
            ),
          ],
        ),
      ]),
      harness_extension.ClientPlugin([
        client_api.Command(
          "/work",
          client_api.Read,
          [],
          client_api.Operation(
            "listWork",
            http.Get,
            "/extensions/work/items",
            [],
            [#("workspace", client_api.Session("/workspace"))],
            [],
            [],
            json.object([]),
            Some(200),
          ),
        ),
      ]),
      harness_extension.GlancePlugin(service.sidebar, service.resource_url),
      harness_extension.ServicePlugin(harness_extension.Service(
        fn(_, _) {
          harness_extension.Admission(harness_extension.DaemonToken, 65_536)
        },
        service.handle,
      )),
      harness_extension.MigrationPlugin(harness_extension.SchemaMigration(
        cwd.apply,
      )),
      harness_extension.CleanPlugin(fn(db, session) {
        store.forget_session(db, ["work"], session)
      }),
      harness_extension.ToolPlugin(
        "Humans and agents share this revision-checked work ledger; every call is async. await work.list(after=0, limit=50), work.get(id), work.create(title, notes=\"\", parent=None), work.update(id, revision=, title=, notes=, status=), and work.delete(id, revision=) return item records: item.id and item[\"id\"] both work, and so do revision, status, title, notes, and parent. Status is open, active, blocked, done, or cancelled. Pass the revision you last read; a stale one raises WorkError, so get the item again. Keep execution status separate from work status. People manage the same ledger with /work, and their changes reach you as notes.",
        [],
        ["work"],
        [],
      ),
      // The prepared workspace scopes both the Python route and /work page.
      harness_extension.ManagedPlugin(fn(store, _, workspace) {
        Ok(
          harness_extension.Managed(..harness_extension.empty(), routes: [
            #("work", fn(_, request) { rpc.handle(store, workspace, request) }),
          ]),
        )
      }),
    ],
    work.initialise,
  )
}
