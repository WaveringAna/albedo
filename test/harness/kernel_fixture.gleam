//// Default extension wiring for standalone kernel tests.

import albedo/daemon/store
import albedo/harness/extensions/python/kernel as python
import albedo/harness/extensions/work/ledger as work
import albedo/harness/extensions/work/rpc
import albedo/harness/rpc as harness_rpc
import gleam/result

pub fn local(
  ledger: store.Store,
  cwd: String,
) -> Result(python.Kernel, python.Error) {
  use _ <- result.try(
    work.initialise(ledger) |> result.map_error(python.Unavailable),
  )
  python.local_with_plugins(
    ledger,
    cwd,
    fn(method, args) {
      rpc.handle(ledger, cwd, method, args) |> harness_rpc.reply
    },
    ["run", "work"],
  )
}
