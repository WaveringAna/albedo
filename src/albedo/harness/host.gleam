//// Dependencies captured from the active composition for one kernel's RPC routes.

import albedo/daemon/store
import albedo/harness/web_search
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}

pub type Context {
  Context(
    store: store.Store,
    session: String,
    searches: List(web_search.Provider),
  )
}

pub type Route =
  #(String, fn(Context, String, Dynamic) -> Result(Json, #(String, String)))
