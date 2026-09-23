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
        "work.list/get/create/update/delete are async; use await. Humans and agents share this revision-checked work ledger. Keep execution status separate from work status.",
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
