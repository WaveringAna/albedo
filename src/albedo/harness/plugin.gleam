//// Explicit tool plugins: Python bindings, optional host RPC, and model tools.
//// Dependencies precede consumers; no discovery or hot loading. Compaction is separate.

import albedo/daemon/store
import albedo/harness/python/kernel as python
import albedo/openai_api/types
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

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

/// Embed a trusted Python module's setup(api) exports in each session's REPL.
/// Short names select packaged modules; dotted names select installed packages.
pub fn python_module(
  name: String,
  module: String,
  instructions: String,
) -> Plugin {
  Plugin(name, instructions, ["python"], [], [module], fn(_) { Ok(Nil) }, [])
}

pub fn install(
  plugins: List(Plugin),
  store: store.Store,
) -> Result(Nil, String) {
  // Validate the whole composition before any plugin initialises storage.
  use _ <- result.try(
    list.try_fold(plugins, #([], [], [], []), fn(installed, plugin) {
      let #(names, tools, routes, modules) = installed
      let new_tools = list.map(plugin.tools, fn(tool) { tool.definition.name })
      let new_routes = list.map(plugin.routes, fn(route) { route.0 })
      let new_modules =
        list.map(plugin.python_modules, fn(name) {
          case string.contains(name, ".") {
            True -> name
            False -> "albedo_plugins." <> name
          }
        })
      let tools = list.append(new_tools, tools)
      let routes = list.append(new_routes, routes)
      let modules = list.append(new_modules, modules)
      case
        string.trim(plugin.name) == ""
        || list.contains(names, plugin.name)
        || !list.all(plugin.requires, list.contains(names, _))
        || tools != list.unique(tools)
        || overlapping_routes(routes)
        || modules != list.unique(modules)
      {
        True ->
          Error(
            "duplicate plugin capability or missing earlier dependency: "
            <> plugin.name,
          )
        False -> Ok(#([plugin.name, ..names], tools, routes, modules))
      }
    }),
  )
  list.try_each(plugins, fn(plugin) { plugin.initialise(store) })
}

pub fn tools(plugins: List(Plugin)) -> List(Tool) {
  list.flat_map(plugins, fn(p) { p.tools })
}

pub fn modules(plugins: List(Plugin)) -> List(String) {
  list.flat_map(plugins, fn(p) { p.python_modules })
}

fn overlapping_routes(routes: List(String)) -> Bool {
  case routes {
    [] -> False
    [route, ..rest] ->
      route == ""
      || list.any(rest, fn(other) {
        route == other
        || string.starts_with(route, other <> ".")
        || string.starts_with(other, route <> ".")
      })
      || overlapping_routes(rest)
  }
}
