import albedo/harness/plugin
import albedo/harness/work/ledger as work
import albedo/harness/work/rpc

pub fn plugin() -> plugin.Plugin {
  plugin.Plugin(
    "work",
    "work.list/get/create/update are async; use await. Humans and agents share this revision-checked work ledger. Keep execution status separate from work status.",
    ["python"],
    [],
    ["work"],
    work.initialise,
    [
      #("work", fn(store, _, request) { rpc.handle(store, request) }),
    ],
  )
}
