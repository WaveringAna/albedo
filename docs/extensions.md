# Extensions
Extensions are basically bundles that provide capabilities to the harness such as oauth, tools, compaction strategies, ways to inject context to the agent, and more. Each extension has a name, description, a list of extensions it depends on, a list of plugins that the extension's capabiltiies fit into, and an initializer.

Extensions can be installed and yet be optional. They can also be toggable as a global default or turned on/off per session.

For a list of built in extensions, see src/albedo/harenss/extensions/

# Plugins
Plugins are typed contribution points and an extension can provide several kinds:
- context: load text for the harness’s model context.
- tools: add model-callable tools, Python modules, and host RPC routes.
- managed: prepare session-specific contributions that depend on the sqlite db, observe session events, and hook into turns.
- commands: provide commands shared by the CLI and the Python kernel callable by the model.
- compaction / folds: provide compaction strategies and stored folds (previous compactions).
- models / model provider: provide catalog data for an inference provider or bridges for oauth from providers such as Claude and Codex
- login: provide a browser-based sign-in flow, often depended on by model provider extensions.
- service: mount daemon HTTP routes under the extension’s path.
- migration: contribute schema setup or data upgrades.

On installation/startup the host calls each extension’s initializer and applies schema migrations. When a session’s enabled extensions are composed, their plugins supply the context, tools, commands, strategies, and other session-facing capabilities. Services and model-provider capabilities are used by daemon-level code rather than being ordinary per-session tools.

## Activation and reload

For implementation and review rules, see [extension boundaries](../robot-docs/extensions.md#boundaries-to-preserve).

Each extension activates as a complete bundle. A failed context loader, managed preparation, or capability collision removes all of that extension's contributions. Extensions that require it also become inactive. The runtime closes rejected managed resources; unrelated extensions keep working.

Saving preferences changes the desired selection. Reload applies it to the session. If application fails, the desired choice remains saved for retry. A matching Python module set keeps the current kernel and rebinds its routes; a changed set stages a replacement and restores its namespace before retiring the old kernel. Failures before shutdown retain the old kernel. Failures after shutdown clear its handle instead of claiming rollback.

Host routes accept a `host.Context` and request string. The context contains the store, session ID, and search providers from the loaded active composition. Global HTTP services use globally enabled extensions instead of session overrides. Search preferences rank or exclude eligible providers without enabling an inactive extension.

## Managed Plugins
A managed plugin has a prepare function that receives the store (the daemon’s durable SQLite-backed store), session id, and workspace, and it returns a `Managed` value. That value can contribute context, instructions, tools, Python modules, routes, commands, and warnings, plus an event observer, a hook, and a close callback.

The observer can receive session events such as provider calls, turn completions, compaction, and session changes. It runs inside the session actor, so it must send and return rather than block or do lengthy work.  The Session capability exposed to managed extensions can make a background provider call, but that call is exclusive work and fails if another run is active or the kernel is released

## Example of creating an extension
A very small existing extension is run. It contributes a tool plugin: instructions for the model, a Python module named run, and a host route named jobs.

```gleam
pub fn extension() -> harness_extension.Extension {
  harness_extension.Extension(
    "run",
    "Start supervised programs from Python, without a shell.",
    ["python"],
    [
      harness_extension.ToolPlugin(instructions, [], ["run"], [
        #("jobs", fn(context: host.Context, request) {
          route(context.store, context.session, request)
        }),
      ]),
    ],
    harness_extension.no_initialise,
  )
}
```

To wire this in for now, import its module and add the extension to the extensions list in harness/extensions.gleam. In the future, there'll be an easier way to load extensions in.

## An example of a managed plugin
Scheudle is a builtin managed plugin. It prepares a session-specific /schedule command using that session’s store and id.  It’s `managed` because the command needs session-specific state

```gleam
pub fn extension() -> extension.Extension {
  extension.Extension(
    "schedule",
    "Durable session prompts, recurring reminders, and idle heartbeats.",
    ["python"],
    [
      extension.ManagedPlugin(fn(db, session, _) {
        Ok(
          extension.Managed(
            ..extension.empty(),
            commands: [command(db, session)],
          ),
        )
      }),
    ],
    ledger.initialise,
  )
}
```

The prepare callback here receives db (the store), session (the session id), and the workspace (unused, hence _). It returns a Managed value with the command wired to that session. The extension’s initializer sets up the schedule ledger.

## Hooks
A managed value can also carry a hook: `hook: Some(fn(hook.Event) -> hook.Verdict)`. The turn asks it at four points and waits for the answer:

- `Prompted(text)`: a user message is about to reach the model.
- `Calling(call)`: a tool call is about to run.
- `Called(call, output, started_ms, finished_ms)`: the call has a result. A refused call gets one too.
- `Stopping(reply, held)`: the model ended its turn without calling a tool. `held` counts how often hooks already kept this turn going.

The answer is a `Verdict`. `hook.proceed` changes nothing. Otherwise it can set `block` (refuse the call or prompt, or keep a stopping turn going), `arguments` (run the call with this JSON instead), `context` (text the model reads before its next request), `notes` (shown to the user only), or `halt` (end the turn). Every hook in the session is asked in registry order. The first block, rewrite and halt win, context and notes add up, and a hook that crashes becomes a note.

Hooks run in the turn's own process, so a slow one slows the turn. One that only watches should send the event to a process of its own and return `hook.proceed` at once.

The agents extension hooks child sessions. A child about to stop while it still owes its parent an answer is asked once to send it:

```gleam
fn answered(
  db: store.Store,
  session: String,
  parent: String,
  event: hook.Event,
) -> hook.Verdict {
  case event {
    hook.Stopping(held: 0, ..) ->
      case mail.owes_reply(db, session, parent) {
        Ok(True) ->
          hook.Verdict(
            ..hook.proceed,
            block: Some("You have not answered your parent yet. ..."),
          )
        _ -> hook.proceed
      }
    _ -> hook.proceed
  }
}
```

### Calls inside a cell
Most of what the model does happens inside one `python` call, so hooks also hear about the calls a cell makes: `run`, `files.edit`, `files.write`, `mcp.call`, `mail.submit`, the agents calls that change another session, `web_search`, the browser actions, every `cua` driver call, and the remote equivalents. Their `within` names the model call that ran the cell. A block raises `PermissionError` in the cell.

A Python plugin reports a call of its own with `albedo_plugins.hook`. Decorate the method and map its parameters to the argument names hooks see:

```python
from albedo_plugins import hook

class Mail:
    @hook.reported("mail.submit", {"to": "to", "body": "body"})
    async def submit(self, to: object, body: str) -> Receipt:
        ...
```

It works on sync and async methods. When the arguments are not the method's parameters, wrap the call itself: `await hook.around(name, arguments, call)` runs `call` on the arguments the hooks left. `hook.before(name, arguments)` and `hook.after(call, output)` are the two halves, for code that has to report the end later, like a job. The kernel loads this module only while some extension in the session has a hook, so a session without hooks pays nothing.

### Command hooks
The `hooks` extension (off by default) runs Claude Code style command hooks from `$ALBEDO_HOME/hooks.json`. It is an ordinary user of the seam above. The file format, matchers, exit codes and output fields are in [robot-docs/hooks.md](../robot-docs/hooks.md).
