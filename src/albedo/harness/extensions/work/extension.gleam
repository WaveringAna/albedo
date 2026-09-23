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
        "Humans and agents share this revision-checked work ledger; every call is async. await work.list(after=0, limit=50), work.get(id), work.create(title, notes=\"\", parent=None), work.update(id, revision=, title=, notes=, status=), and work.delete(id, revision=) return plain dicts (item[\"id\"], item[\"revision\"], item[\"status\"]). Status is open, active, blocked, done, or cancelled. Pass the revision you last read; a stale one raises WorkError, so get the item again. Keep execution status separate from work status. People manage the same ledger with /work, and their changes reach you as notes.",
        [],
        ["work"],
        [#("work", fn(store, _, request) { rpc.handle(store, request) })],
      ),
      // The /work page needs the ledger handle, which only a prepared plugin receives.
      harness_extension.ManagedPlugin(fn(store, _, _) {
        Ok(
          harness_extension.Managed(
            "",
            "",
            [],
            [],
            [],
            [work_command.command(store)],
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
