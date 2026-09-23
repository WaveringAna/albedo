# extensions

an extension is a named bundle of plugins. it can contribute any number of context, tool, command, managed, or compaction plugins. `python`, `bash`, `work`, `files`, `commands`, `skills`, `rolling`, and `remote` are enabled by default; `mcp` and `view` are installed and disabled until a session enables them. plugin contributions compose inside them.

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

`CommandPlugin` supplies [session commands](commands.md): the same catalog drives the CLI menu, user invocation, and the kernel's typed `commands` bindings. duplicate command names are rejected with the other capability collisions.

A command may also be an extension's own **page**: set `page: True` and, run with no arguments, answer a [`page.Document`](../src/albedo/harness/page.gleam) — a title, rows with a badge and tone, the actions available on them, and an optional short glance. The CLI opens a bare `/name` of a page command as that screen and renders it generically: each action runs the same command with `action` = the action's `run` and `details` = the selected row's id followed by any entered text, chosen option, or preset value, and the page is fetched again afterwards. A glance appears in the chat's right margin when the terminal leaves room beside the 100-column body, and as a count in the header when it does not. `/work` is the first page; a skills toggle or an MCP server list would declare theirs the same way, with no client changes.

A command that tells the agent about a user's change uses the `Note(origin, display, text)` state operation: the note waits in the session's queue, reaches the model at its next step if a run is active or ahead of the user's next message if not, and never starts a turn by itself.

`ManagedPlugin` prepares session-owned contributions together: context, tool instructions, tools, python modules, host routes, and commands. preparation returns a close callback. a failed replacement releases its prepared resources and leaves the old selection active; successful replacement releases the old resources after the swap. use this for connections or an immutable catalog shared by context and tools.

`ModelsPlugin` supplies catalogued model facts and provider model lists. `ModelProviderPlugin` declares its models.dev namespace and resolves a tagged saved profile into a request client. Built-in dependencies keep these layers explicit: `codex -> openai -> models`. See [models](models.md) and [model authentication](auth.md).

`CompactionPlugin` supplies a history strategy; see [compaction](compaction.md). at most one enabled compaction strategy owns the request-history view. a strategy receives chronological history and must preserve tool call/result associations; it must not replace the durable transcript.

## extension settings

optional `$ALBEDO_HOME/extensions.json` (default `~/.albedo/extensions.json`) holds named extension settings separately from provider credentials and session selection. settings are read when preparing a worker; changing a file does not mutate an existing session composition. missing sections use extension defaults. invalid settings fail preparation without replacing the live worker.

## python bindings

an explicitly registered python module exports `setup(api)`, which may be a plain function or an async function (awaited at kernel boot, so a plugin can fetch its catalog through `api.host` before the handshake):

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
- `api.attach_image(data)` attaches PNG, JPEG, or WebP bytes to the running cell's result.

## images in tool results

a cell returns images with `show_image(bytes_or_path)`, or a plugin with `api.attach_image(data)`: at most 4 images and 5 MiB per cell, and only while the cell runs. a background task a finished cell left behind has no result to carry one, so it gets an error. the harness reads each image's header again before sending it; one it cannot read is named under `image_errors` in the result text and not sent.

on the wire, responses sends the images inside `function_call_output.output`, after the text. chat completions tool messages take text only, so after a run of tool results one user message carries their images, each group labelled with its call id. history keeps the images on the tool result itself, so compaction never mistakes that message for a user turn. the model must accept image input; nothing checks that yet.

interfaces: [`PythonApi`](../priv/python/albedo_api.py), [`work`](../src/albedo/harness/work.gleam), [`compaction strategy`](../src/albedo/harness/compaction.gleam).

## bash

`bash(command)` starts a supervised job that owns its process group; output stays on the handle (`job.tail()`, `output.read(job.id)`) and finished handles stay addressable in `jobs`. a job that finishes with its result unread wakes the session: the kernel reports the completion through the `jobs` host route, and the session submits a user turn naming the job, its exit, and how to read it, so the model never polls or awaits a handle just to learn it finished. awaiting the job, reading its result, or stopping it retires the wake. a busy session is retried, not queued in gleam: the kernel retries the notice until the run ends or the result is read. live jobs pin the kernel against the idle sweep — a detached session is not released while background work still runs, local or remote, because releasing it would kill the job and the wake it owes. remote `bash` jobs wake the same way — the remote kernel's host calls relay over the ssh connection into this session's route, and the notice names the host — and a mirror read (`rem_job.tail()`) tells the remote job it was read through one `poll` round trip.

## view

optional. `await view_code(path, start_line=1, end_line=None, *, columns=79)` renders a range as syntax-highlighted PNG pages and returns them with the cell's result (see [images in tool results](#images-in-tool-results)). its instructions ask the model for a final review pass before it reports code work as done: view each changed region, check it against the surrounding style, for repetition an existing helper should carry, and for leftovers, fix, and view again.

the whole file is highlighted, so a range starting inside a comment or string is colored correctly. lines wrap at `columns`, tabs expand to 4, wide characters take two cells. up to 4 pages of about 80 rows, split evenly at line boundaries; the returned text names each page's lines and the call that continues.

rendering is `albedo-render`, a rust binary in `native/render` (arborium's tree-sitter grammars, bundled JetBrains Mono), run as a supervised `bash` job. `native/render/install.sh` builds it into `priv/bin`; `PATH` also works. a language without a compiled-in grammar renders unhighlighted.

## work

`work` is a revision-checked ledger shared by humans and agents. The model uses `await work.list/get/create/update/delete`. People use `/work`, its page: `a` adds an item, `e` renames, `d` marks done, `s` sets a status, and `x` removes one (an item with sub-items stays). Typed forms work too: `/work add <title>`, `/work edit <id> <title>`, `/work status <id> <status>`, `/work remove <id>`. Every change a person makes is queued as a note for the agent. Open items appear beside the conversation when the terminal is wide enough.

## files

see [the files extension](files.md): bounded reads, guarded exact edits, and ripgrep search that runs as a supervised `bash` job instead of a raw subprocess.

## models

see [the models catalog](models.md): the cached models.dev catalog that supplies context windows, modalities, and provider endpoints to compaction and `/context`.

## commands

see [the commands extension](commands.md) for the full contract. `CommandPlugin` contributes static commands and `Managed.commands` dynamic ones; runs execute outside the session actor and reach state only through the registered state seam.

## mcp

see [the mcp extension](mcp.md) for connecting Model Context Protocol servers: configuration, credential scope, namespaced tools, and connection lifecycle.

## remote

the `remote` extension boots this session's Python kernel on a remote host over one SSH connection, so every harness tool is callable on it, and it is enabled by default. `rem = await remote.connect()` stages albedo's python bundle on the target, starts the kernel there through SSH with `ControlMaster`/`ControlPersist` (one multiplexed TCP connection: no re-authentication per call), and answers the remote kernel's host-route calls against this session's daemon.

machine tools run on the remote kernel: `rem.bash(command)` starts a supervised job on the host immediately and synchronously, like local bash — the handle exists right away, `job.tail()`, `job.id`, `job.exit_code`, `job.duration`, and `job.timed_out` answer synchronously from the mirrored output stream, `await job` waits for completion, and `await job.stop()` stops it. session tools run where the daemon runs: `await rem.work.*` and `await rem.skills.*` relay over the connection to the local daemon's ledger and catalog. both kernels load the same content-hashed bundle, so a tool's remote shape matches its local one. every other call returns a reference that settles on its first await: values cross as real objects — dataclasses and list subclasses are rebuilt, so remote output prints exactly like local output — and a result that cannot cross comes back as a live reference whose methods are further remote calls. references passed back into remote calls stay references, not copies, including ones still in flight. one rule remains: a call whose local counterpart is synchronous (`rem.files.read`) still needs `await`, because the value itself crosses the network; handles and their state never do.

the target resolves per call from a `host=` argument, then `remote.configure(host, remote_cwd=None)`, then `$ALBEDO_SSH` (`user@host[:/path]`), then the `remote` section of extensions.json:

```json
{
  "remote": { "host": "deploy@box", "remoteCwd": "/srv/app", "python": "python3" }
}
```

a bare host asks the remote for its `pwd` once. if the host is reachable but its kernel cannot boot (no python, staging failed, bad handshake), `connect()` still returns and prints a warning: the connection is degraded to SSH command mode, where only `rem.bash(command, timeout=300)`, `rem.read(path)`, and `rem.write(path, content)` answer and everything else raises. an unreachable host fails `connect()`. connections are scoped: a lost SSH channel invalidates the connection rather than silently reconnecting, and `await rem.close()` ends it. connections run under `BatchMode=yes`, so key-based auth is required.

## skills

see [the skills extension](skills.md) for discovery paths, metadata-only startup context, and on-demand reading of actual `SKILL.md` files and resources. skills requires python: every cataloged skill is a [session command](commands.md) with a typed `commands.<method>(...)` binding, while users invoke the listed slash command. both resolve the same session catalog and the same activation. the model caller receives instructions as data without submitting another turn; the user caller submits one activation turn. installing or reading a skill does not run its scripts or import its code automatically.

## rolling compaction

`rolling` is the enabled-by-default compaction strategy: summary, recent-user recap, then a verbatim tail, triggered by remaining context. see [compaction](compaction.md) for its contract, settings, and state handling.
