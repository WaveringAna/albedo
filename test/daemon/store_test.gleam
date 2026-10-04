//// A store query waits for its answer with no deadline, so a store that stops
//// must end the wait at once. A daemon run never stops its store under a
//// waiting caller, so only this test sees a hang there.

import albedo/daemon/store
import gleam/erlang/process

pub fn a_query_on_a_stopped_store_fails_at_once_test() -> Nil {
  let assert Ok(db) = store.start(":memory:", "")
  store.close(db)
  let caller =
    process.spawn_unlinked(fn() {
      store.query(db, fn(_) { Nil })
      Nil
    })
  let monitor = process.monitor(caller)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
    as "the caller is still waiting on a stopped store"
  Nil
}
