//// Dependencies captured from the active composition for one kernel's RPC routes.

import albedo/daemon/store
import albedo/harness/web_search

pub type Context {
  Context(
    store: store.Store,
    session: String,
    searches: List(web_search.Provider),
  )
}

pub type Route =
  #(String, fn(Context, String) -> String)
