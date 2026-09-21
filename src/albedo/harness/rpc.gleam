import albedo/daemon/store
import albedo/harness/plugin
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string

pub fn handle(
  plugins: List(plugin.Plugin),
  store: store.Store,
  session: String,
  request: String,
) -> String {
  let method =
    json.parse(request, decode.field("method", decode.string, decode.success))
  let routes = list.flat_map(plugins, fn(p) { p.routes })
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

const unavailable = "{\"ok\":false,\"code\":\"unavailable\",\"message\":\"plugin capability unavailable\"}"
