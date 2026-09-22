import albedo/harness/extension as harness_extension
import albedo/harness/work/ledger as work
import albedo/harness/work/rpc

pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "work",
    "A durable revision-checked work ledger shared by humans and agents.",
    ["python"],
    [
      harness_extension.ToolPlugin(
        "work.list/get/create/update are async; use await. Humans and agents share this revision-checked work ledger. Keep execution status separate from work status.",
        [],
        ["work"],
        [#("work", fn(store, _, request) { rpc.handle(store, request) })],
      ),
    ],
    work.initialise,
  )
}

pub fn plugin() -> harness_extension.Extension {
  extension()
}
