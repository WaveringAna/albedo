# extensions

an extension is a named bundle of plugins. it can contribute any number of context, tool, managed, or compaction plugins. `python`, `bash`, `work`, `skills`, and `rolling` are enabled by default; `mcp` and `ssh` are installed and disabled until a session enables them. plugin contributions compose inside them.

## select extensions

open `/extensions` in a session to inspect installed extensions and enable or disable them. selection is saved per session. required extensions must stay enabled, and changes require an idle session.

confirming a change reloads that session's workers, context, model tools, python bindings, and host routes. it does not restart the daemon or rewrite the conversation. changing the prompt prefix/tools busts prompt-cache reuse. python variables are saved and restored where possible; values that cannot be saved may be lost. the viewer warns before applying a change.

## installed and enabled

`extensions.Config(installed, default_enabled)` separates installed extensions from their default selection. multiple compaction strategies may be installed, but at most one can be enabled for a session. `runtime.start_with_config(database, config)` uses this selection; `runtime.start_with_extensions(database, installed)` enables every supplied extension.

## contribute plugins

interfaces live in [`extension.gleam`](../src/albedo/harness/extension.gleam); built-in composition lives in [`extensions.gleam`](../src/albedo/harness/extensions.gleam).

```gleam
extension.Extension(
  name: "project-context",
  description: "workspace instructions for the model",
  requires: [],
  plugins: [extension.ContextPlugin(load: load_workspace_context)],
  initialise: fn(_) { Ok(Nil) },
)
```

`ContextPlugin.load(workspace)` returns `Result(String, String)`. its request-only content is loaded for the current workspace and placed after the system prompt, before conversation history. it is not appended to the durable transcript. model requests keep extension context separate from history compaction.

`ToolPlugin` supplies model-facing tools, python modules, host routes, and tool instructions. model tools declare a definition, an invocation callback, and a recovery callback. recovery must report a stored result or unknown outcome, not replay a potentially side-effecting operation.

`ManagedPlugin` prepares session-owned contributions together: context, tool instructions, tools, python modules, and host routes. preparation returns a close callback. a failed replacement releases its prepared resources and leaves the old selection active; successful replacement releases the old resources after the swap. use this for connections or an immutable catalog shared by context and tools.

`ModelsPlugin` answers `lookup(model, endpoint)` with catalogued model facts, or nothing when the model is unknown; see [models](models.md).

`CompactionPlugin` supplies a history strategy; see [compaction](compaction.md). at most one enabled compaction strategy owns the request-history view. a strategy receives chronological history and must preserve tool call/result associations; it must not replace the durable transcript.

## extension settings

optional `$ALBEDO_HOME/extensions.json` (default `~/.albedo/extensions.json`) holds named extension settings separately from provider credentials and session selection. settings are read when preparing a worker; changing a file does not mutate an existing session composition. missing sections use extension defaults. invalid settings fail preparation without replacing the live worker.

## python bindings

an explicitly registered python module exports `setup(api)`:

```python
def setup(api):
    def double(n):
        return n * 2
    return {"double": double}
```

packaged short names resolve to `albedo_plugins.*`; dotted names select installed packages. this is the python tool-plugin module namespace, not the name of the enclosing extension. imports happen before the workspace enters the import path.

- `setup(api)` runs per kernel; duplicate and reserved bindings are rejected.
- `api.on_shutdown(close)` registers cleanup.
- `api.background_handle(Type)` marks a returned background handle.
- `api.capture(id)` retains bounded output.
- `await api.host("namespace.method", args)` calls an enabled host route.

interfaces: [`PythonApi`](../priv/python/albedo_api.py), [`work`](../src/albedo/harness/work.gleam), [`compaction strategy`](../src/albedo/harness/compaction.gleam).

## files

see [the files extension](files.md): bounded reads, guarded exact edits, and ripgrep search that runs as a supervised `bash` job instead of a raw subprocess.

## models

see [the models catalog](models.md): the cached models.dev catalog that supplies context windows, modalities, and provider endpoints to compaction and `/context`.

## mcp

see [the mcp extension](mcp.md) for connecting Model Context Protocol servers: configuration, credential scope, namespaced tools, and connection lifecycle.

## ssh

the `ssh` extension runs commands and moves files on one remote host; installed and disabled until a session enables it. `ssh.run(command)` executes remotely and returns its exit code and output; exit code 255 usually means the connection itself failed. `ssh.read(path)` returns remote file text and `ssh.write(path, content)` replaces it. paths under the session workspace map onto the remote cwd. the target resolves per call from a `host=` argument, then the value `ssh.configure(host, remote_cwd=None)` stored, then `$ALBEDO_SSH` (`user@host[:/path]`), then the `ssh` section of extensions.json:

```json
{
  "ssh": { "host": "deploy@box", "remoteCwd": "/srv/app" }
}
```

a bare host asks the remote for its `pwd` once. commands run under `BatchMode=yes`, so key-based auth is required.

## skills

see [the skills extension](skills.md) for discovery paths, metadata-only startup context, and on-demand reading of actual `SKILL.md` files and resources. skills requires python: the model uses `await skills.activate(name, arguments)`, while users invoke the listed slash command. both resolve the same session catalog. python activation returns instructions without submitting another turn. installing or reading a skill does not run its scripts or import its code automatically.

## rolling compaction

`rolling` is the enabled-by-default compaction strategy: summary, recent-user recap, then a verbatim tail, triggered by remaining context. see [compaction](compaction.md) for its contract, settings, and state handling.
