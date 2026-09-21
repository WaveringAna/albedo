//// Explicit composition. Dependencies must precede consumers; no discovery or hot loading.

import albedo/daemon/store
import albedo/harness/python/kernel as python
import albedo/openai_api/types
import gleam/list
import gleam/option.{type Option}
import gleam/result

pub type Context {
  Context(
    store: store.Store,
    session: String,
    kernel: python.Kernel,
    call_id: String,
  )
}

pub type Tool {
  Tool(
    definition: types.Tool,
    invoke: fn(Context, String) -> Result(String, String),
    recover: fn(Context) -> Option(String),
  )
}

pub type Plugin {
  Plugin(
    name: String,
    instructions: String,
    requires: List(String),
    tools: List(Tool),
    python_modules: List(String),
    initialise: fn(store.Store) -> Result(Nil, String),
    routes: List(#(String, fn(store.Store, String, String) -> String)),
  )
}

pub fn install(
  plugins: List(Plugin),
  store: store.Store,
) -> Result(Nil, String) {
  use _ <- result.try(
    list.try_fold(plugins, #([], [], []), fn(installed, plugin) {
      let #(names, tools, routes) = installed
      let new_tools = list.map(plugin.tools, fn(tool) { tool.definition.name })
      let new_routes = list.map(plugin.routes, fn(route) { route.0 })
      case
        list.contains(names, plugin.name)
        || !list.all(plugin.requires, list.contains(names, _))
        || list.any(new_tools, list.contains(tools, _))
        || list.any(new_routes, list.contains(routes, _))
      {
        True ->
          Error(
            "duplicate plugin capability or missing earlier dependency: "
            <> plugin.name,
          )
        False -> {
          use _ <- result.try(plugin.initialise(store))
          Ok(#(
            [plugin.name, ..names],
            list.append(new_tools, tools),
            list.append(new_routes, routes),
          ))
        }
      }
    }),
  )
  Ok(Nil)
}

pub fn tools(plugins: List(Plugin)) -> List(Tool) {
  list.flat_map(plugins, fn(p) { p.tools })
}

pub fn modules(plugins: List(Plugin)) -> List(String) {
  list.flat_map(plugins, fn(p) { p.python_modules })
}
