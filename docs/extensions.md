# Extensions
Extensions are basically bundles that provide capabilities to the harness such as oauth, tools, compaction strategies, ways to inject context to the agent, and more. Each extension has a name, description, a list of extensions it depends on, a list of plugins that the extension's capabiltiies fit into, and an initializer.

Extensions can be installed and yet be optional. They can also be toggable as a global default or turned on/off per session.

For a list of built in extensions, see src/albedo/harenss/extensions/

# Plugins
Plugins are typed contribution points and an extension can provide several kinds:
- context: load text for the harness’s model context.
- tools: add model-callable tools, Python modules, and host RPC routes.
- managed: prepare session-specific contributions that depend on the sqlite db and observe session events.
- commands: provide commands shared by the CLI and the Python kernel callable by the model.
- compaction / folds: provide compaction strategies and stored folds (previous compactions).
- models / model provider: provide catalog data for an inference provider or bridges for oauth from providers such as Claude and Codex
- login: provide a browser-based sign-in flow, often depended on by model provider extensions.
- service: mount daemon HTTP routes under the extension’s path.
- migration: contribute schema setup or data upgrades.

On installation/startup the host calls each extension’s initializer and applies schema migrations. When a session’s enabled extensions are composed, their plugins supply the context, tools, commands, strategies, and other session-facing capabilities. Services and model-provider capabilities are used by daemon-level code rather than being ordinary per-session tools.

## Managed Plugins
A managed plugin has a prepare function that receives the store (the daemon’s durable SQLite-backed store), session id, and workspace, and it returns a `Managed` value. That value can contribute context, instructions, tools, Python modules, routes, commands, and warnings, plus an event observer and a close callback.

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
        #("jobs", route),
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
