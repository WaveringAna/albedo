import albedo/daemon/store
import albedo/harness/extension
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

pub fn handle(
  routes: List(extension.Route),
  store: store.Store,
  session: String,
  request: String,
) -> String {
  let method =
    json.parse(request, decode.field("method", decode.string, decode.success))
  case method {
    Ok(method) ->
      case
        list.find(routes, fn(route) {
          string.starts_with(method, route.0 <> ".")
        })
      {
        Ok(#(_, run)) -> run(store, session, request)
        Error(_) -> unavailable
      }
    Error(_) -> unavailable
  }
}

const unavailable = "{\"ok\":false,\"code\":\"unavailable\",\"message\":\"extension capability unavailable\"}"
