import albedo/harness/extension as harness_extension
import albedo/harness/extensions/work/command as work_command
import albedo/harness/extensions/work/ledger as work
import albedo/harness/extensions/work/rpc

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "work",
    "A durable revision-checked work ledger shared by humans and agents.",
    ["python"],
    [
      harness_extension.ToolPlugin(
        "Humans and agents share this revision-checked work ledger; every call is async. await work.list(after=0, limit=50), work.get(id), work.create(title, notes=\"\", parent=None), work.update(id, revision=, title=, notes=, status=), and work.delete(id, revision=) return item records: item.id and item[\"id\"] both work, and so do revision, status, title, notes, and parent. Status is open, active, blocked, done, or cancelled. Pass the revision you last read; a stale one raises WorkError, so get the item again. Keep execution status separate from work status. People manage the same ledger with /work, and their changes reach you as notes.",
        [],
        ["work"],
        [],
      ),
      // The prepared workspace scopes both the Python route and /work page.
      harness_extension.ManagedPlugin(fn(store, _, workspace) {
        Ok(
          harness_extension.Managed(
            "",
            "",
            [],
            [],
            [
              #("work", fn(_, _, request) {
                rpc.handle(store, workspace, request)
              }),
            ],
            [work_command.command(store, workspace)],
            [],
            fn() { Nil },
          ),
        )
      }),
    ],
    work.initialise,
  )
}

pub fn plugin() -> harness_extension.Extension {
  extension()
}
