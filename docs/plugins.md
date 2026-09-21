# plugins

explicit composition in [`plugins.defaults()`](../src/albedo/harness/plugins.gleam). tool plugins compose; compaction is `None` or one `Some(strategy)`. no discovery or hot loading yet.

## write a repl tool

`priv/python/albedo_plugins/example.py`:

```python
def setup(api):
    def double(n):
        return n * 2
    return {"double": double}
```

register it in `plugins.defaults()`:

```gleam
pub fn defaults() -> Config {
  Config([
    python.plugin(), bash.plugin(), work.plugin(),
    plugin.python_module("example", "example", "double(n) doubles n."),
  ], None)
}
```

then the model calls `double(21)` inside python. short module names resolve to `albedo_plugins.*`; dotted names import installed packages, before the workspace enters the import path. registration is in code; restart to load changes.

- `setup(api)` runs per kernel and returns public python names. duplicate/reserved bindings (`cells`, `output`, `__name__`) are rejected.
- `api.on_shutdown(close)` registers sync/async cleanup; `api.background_handle(Type)` prevents automatic awaiting of returned handles.
- `api.capture(id)` retains background output. `await api.host("namespace.method", args)` calls a registered host route.
- host-backed plugins supply `initialise`, `routes`, and earlier `requires` dependencies. see [`work.gleam`](../src/albedo/harness/work.gleam) and [`work.py`](../priv/python/albedo_plugins/work.py).
- repl exports do not add model-facing function tools. those use [`plugin.Tool`](../src/albedo/harness/plugin.gleam), including an explicit recovery callback.

## compaction: extension point only

no algorithm is shipped. to test the slot, import `Some` from `gleam/option` and use this body in `plugins.defaults()`:

```gleam
let strategy = compaction.Strategy("identity", fn(_context, history) {
  Ok(history)
})
Config([python.plugin(), bash.plugin(), work.plugin()], Some(strategy))
```

`prepare(context, history)` runs before each model request with chronological inputs. context provides `store`, `session`, `kernel`, and `model`. return `Ok(request_history)` or `Error(reason)` to stop the turn. preserve tool call/result pairs. the durable transcript stays untouched; the strategy owns any summary/state storage.

interfaces: [`PythonApi`](../priv/python/albedo_api.py), [`Plugin`](../src/albedo/harness/plugin.gleam), [`Strategy`](../src/albedo/harness/compaction.gleam). embedders select the same config through `runtime.start_with_config(database, config)`.
