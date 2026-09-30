# extensions

Persisted preferences are owned by the daemon and changed through the [settings API](settings.md). The CLI refreshes them on use and never writes settings files.


an extension is a named bundle of plugins. it can contribute any number of context, tool, command, managed, models, provider, login, service, migration, compaction, or fold plugins. `python`, `run`, `work`, `mail`, `agents`, `schedule`, `paperclips`, `files`, `memory`, `instructions`, `commands`, `skills`, `models`, `openai`, `codex`, `antigravity`, `alibaba`, `claude`, `rolling`, `snapcompact-memory`, `lcm-memory`, and `remote` are enabled by default; `mcp`, `view`, [`proxy`](proxy.md), `webhooks`, [`warm`](cache-warming.md), and the `snapcompact` and `lcm` compaction strategies are installed and disabled until enabled. plugin contributions compose inside them.

## select extensions

open `/extensions` in a session to inspect installed extensions and enable or disable them. selection is saved per session. enabling a compaction strategy disables the previously selected strategy in the same reload. to replace the active strategy, enable the new one; disabling the only active strategy is rejected. required extensions must stay enabled, and changes require an idle session.

confirming a change reloads that session's workers, context, model tools, python bindings, and host routes. it does not restart the daemon or rewrite the conversation. changing the prompt prefix/tools busts prompt-cache reuse. python variables are saved and restored where possible; values that cannot be saved may be lost. the viewer warns before applying a change.

## installed and enabled

`extensions.Config(installed, default_enabled)` separates installed extensions from their default selection. multiple compaction strategies may be installed, but at most one can be enabled for a session. built-in sessions start with `rolling`; custom hosts can omit compaction. `runtime.start_with_config(database, config)` uses this selection; `runtime.start_with_extensions(database, installed)` enables every supplied extension.

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

`ContextPlugin.load(workspace)` returns `Result(String, String)`. its request-only content is loaded for the current workspace and included in the system instructions, after core and extension instructions. it is not appended to the durable transcript. model requests keep extension context out of history compaction. Live reloads keep the cached system prefix and add a concise capability-change notice to history, providing replacement named context blocks (including command and skill metadata) and explicit removal notices relative to the previous live context; unchanged blocks are not replayed. The updated system instructions replace that prefix when compaction rewrites history. A changed tool schema necessarily changes the provider tool registry immediately.

`ToolPlugin` supplies model-facing tools, python modules, host routes, and tool instructions. model tools declare a definition, an invocation callback, and a recovery callback. recovery must report a stored result or unknown outcome, not replay a potentially side-effecting operation.

`CommandPlugin` supplies [session commands](commands.md): the same catalog drives the CLI menu, user invocation, and the kernel's typed `commands` bindings. duplicate command names are rejected with the other capability collisions.

A command may also be an extension's own **page**: set `page: True` and, run with no arguments, answer a [`page.Document`](../src/albedo/harness/page.gleam) — a title, rows with a badge, a tone, and an optional detail shown for the selected row (beside the list when the terminal is wide, under it when not), the actions available on them, and an optional short glance. The CLI opens a bare `/name` of a page command as that screen and renders it generically: each action runs the same command with `action` = the action's `run` and `details` = the selected row's id followed by any entered text, chosen option, or preset value, and the page is fetched again afterwards. The first glance with rows appears in the chat's right margin when the terminal leaves room beside the 100-column body; every glance the margin leaves out shows as a count in the header. `/work` is the first page; a skills toggle or an MCP server list would declare theirs the same way, with no client changes.

A command that tells the agent about a user's change uses the `Note(origin, display, text)` state operation: the note waits in the session's queue, reaches the model at its next step if a run is active or ahead of the user's next message if not, and never starts a turn by itself.

`ManagedPlugin` prepares session-owned contributions together: context, tool instructions, tools, python modules, host routes, and commands. preparation returns a close callback. a failed replacement releases its prepared resources and leaves the old selection active; successful replacement releases the old resources after the swap. use this for connections or an immutable catalog shared by context and tools.

a managed contribution also hears its session through `observe(session, event)`, which runs inside the session actor and so must only send and return. events arrive in order: `CallSent` for each successful turn call as it went out (request, prefix identity, usage, cache marks, profile, endpoint, protocol, timing), `TurnEnded(cancelled)`, `Compacted` after a forced compaction, and `Stirred` for any new activity. the `extension.Session` handle it comes with names the session and offers `call(request, prefix)`: any `types.Request`, sent on the session's upstream as exclusive work that queues submissions behind it, records a provider request row of kind `background` under `prefix`, and never reaches the transcript or the stream. it blocks its caller until the call ends and fails at once while another run holds the session or its kernel is released. `extension.empty()` is the contribution with nothing in it, for record updates; [`warm`](cache-warming.md) is built on these two seams alone.

`ModelsPlugin` supplies catalogued model facts and provider model lists. `ModelProviderPlugin` declares its models.dev namespace and resolves a tagged saved profile into an `Upstream`: a `stream` function over albedo's request, event, and turn types, plus the endpoint, replay protocol, and an `explain` for failures. A provider with its own wire format encodes an `openai_api.Exchange` and passes it with its own `stream.Reducer` to `openai_api.exchange`, which keeps HTTP, SSE framing, limits, and callbacks shared; `antigravity` does this. `LoginPlugin` supplies a browser sign-in that the daemon runs for every client; see [model authentication](auth.md#sign-in-api).

`ServicePlugin(Service(handle))` serves HTTP from the daemon while its extension is enabled globally (sessions do not select services). Requests to `/<extension>/...` go to `handle(daemon, path, request)` with the path below the mount. The daemon token does not apply there, so a service owns its own authentication; requests carrying an `Origin` header are still refused, so a web page cannot reach a local service that spends your credentials. The daemon's own routes (`health`, `sessions`, `models`, `auth`, `shutdown`) always win. `extension.Daemon` gives the service `home`, `upstream(profile, model, session)` to resolve a saved profile outside any session, catalog `models`, and the daemon's `sessions`. Set `ALBEDO_PORT` in the daemon's environment to pin its port so a service has a stable base url; the default is a free port chosen at start. Built-in dependencies keep these layers explicit: `codex -> openai -> models`. See [models](models.md) and [model authentication](auth.md).

`CompactionPlugin` supplies a history strategy; `FoldPlugin` supplies stored folds any strategy reads through `context.prior`; see [compaction](compaction.md). one enabled compaction strategy owns the request-history view in a built-in session. a strategy receives chronological history and must preserve tool call/result associations; it must not replace the durable transcript.

## sqlite migrations

extensions own their tables and their SQLite migration implementations. contribute
`MigrationPlugin(SchemaMigration(apply))` for column/index upgrades and
`MigrationPlugin(DataMigration(name, run))` for data rewrites; keep the callbacks
under the owning extension, not `daemon/migrations/`.

`extension.install` calls each installed owner's `initialise(ledger)` to create
its tables, then applies that owner's schema callbacks on the serialized store
connection before proceeding to the next owner. `runtime.migrate(host, backup)`
collects and applies data callbacks in registry/plugin order after the daemon's
core data upgrades and before sessions start. `run(ledger, backup)` returns a
rewritten-row count. installed-but-disabled extensions still upgrade their
storage; session selection/reload does not apply migrations. failures stop the
phase, and data callbacks own their idempotency markers, paging, and transactions.
embedding hosts must prepare core storage and invoke `runtime.migrate` before
opening sessions. see [migrations](migrations.md) for startup order and backups.

```gleam
plugins: [
  extension.MigrationPlugin(extension.SchemaMigration(title.apply)),
],
```

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

a cell returns images with `show_image(bytes_or_path)`, or a plugin with `api.attach_image(data)`: at most 4 images and 5 MiB per cell, each within the session provider's image edge (the daemon sends it with every cell), and only while the cell runs; past any of these the call raises `ValueError`. The kernel reads dimensions with its own port of the daemon's header parser (`image_size` in `albedo_kernel.py`, held to `albedo_image.erl` by `test/harness/image_header_parity_test.gleam`). a background task a finished cell left behind has no result to carry one, so it gets an error. the harness reads each image's header again before sending it, as the authority; one it cannot read, or one larger than the session's provider accepts (a plugin's image under a stale edge, say) (see [models](models.md)), is named under `image_errors` in the result text and not sent.

on the wire, responses sends the images inside `function_call_output.output`, after the text. chat completions tool messages take text only, so after a run of tool results one user message carries their images, each group labelled with its call id. history keeps the images on the tool result itself, so compaction never mistakes that message for a user turn. the model must accept image input; nothing checks that yet.

interfaces: [`PythonApi`](../priv/python/albedo_api.py), [`work`](../src/albedo/harness/work.gleam), [`compaction strategy`](../src/albedo/harness/compaction.gleam).

## run

`run(program, *args, cwd=, env=, stdin=)` starts one program, without a shell, as a supervised job that owns its process group; output stays on the handle (`job.tail()`, `output.read(job.id)`) and finished handles stay addressable in `jobs`. a job that finishes with its result unread wakes the session: the kernel reports the completion through the `jobs` host route, and the session submits a user turn naming the job, its exit, and how to read it, so the model never polls or awaits a handle just to learn it finished. awaiting the job, reading its result, or stopping it retires the wake. a busy session is retried, not queued in gleam: the kernel retries the notice until the run ends or the result is read. live jobs pin the kernel against the idle sweep — a detached session is not released while background work still runs, local or remote, because releasing it would kill the job and the wake it owes. remote `run` jobs wake the same way — the remote kernel's host calls relay over the ssh connection into this session's route, and the notice names the host — and a mirror read (`rem_job.tail()`) tells the remote job it was read through one `poll` round trip.

there is no shell, so shell syntax has python spellings: `cd dir &&` is `cwd=`, `NAME=value` is `env=`, `| tail -n N` and `| head -n N` are `job.tail(lines=N)` and `job.head(lines=N)`, stderr always joins stdout, and chains, loops, and globs are python over the job's output. `a | b` is `run(a…).pipe(b…)`, the same as `run(b…, stdin=job)`: the writer's bytes stream into the reader exactly, a full reader pauses the writer, and once every reader has closed its stdin the kernel stops reading the writer, so its next write fails as it would into a closed shell pipe (`run('yes').pipe('head', '-2')` ends). the writer still captures its own output; piping retires its wake, and the reader's notice names the whole pipeline. a job that already wrote feeds what it retained first; one that wrote past the 1 MiB it retains cannot be piped after the fact. `run("bash", "-c", …)` and its spellings are refused, and so is a cell's own `subprocess`, `os.system`, `os.exec*`, `os.posix_spawn`, or `asyncio.create_subprocess_*` — an audit hook in `albedo_shell` checks whether the nearest non-stdlib frame is cell code. each refusal carries the `run()` call the line means when it is simple enough to read (`cd cli && go test ./... | tail -5` → `job = await run('go', 'test', './...', cwd='cli')` then `job.tail(lines=5)`), so the error is a copy-paste answer rather than a wall. this is guidance, not a sandbox: plugins and libraries a cell calls still spawn, and `exec` of a compiled string is not cell code.

## view

optional. `await view_code(path, start_line=1, end_line=None, *, columns=79)` renders a range of one file as syntax-highlighted PNG pages, and `await view_diff(path=".", start_line=1, *, staged=False, columns=80)` renders `git diff` the same way, without line numbers since a diff's own lines are not the file's. both return the pages with the cell's result (see [images in tool results](#images-in-tool-results)). the instructions ask the model for a final review pass before it reports code work as done: `view_diff` for every change, `view_code` for context and untracked files, checked against the surrounding style, for repetition an existing helper should carry, and for leftovers; fix, then view again.

the whole file is highlighted, so a range starting inside a comment or string is colored correctly. lines wrap at `columns`, with an arrow in the gutter on each continuation row; tabs expand to 4, wide characters take two cells. up to 4 pages of at most 80 display rows, split evenly at line boundaries, so wrap-heavy code fits fewer source lines per page. the returned text names each page's lines and the call that continues. `view_diff` leaves out files git does not track and asks git for a repository first, so outside one it says so.

rendering is `albedo-render`, a rust binary in `native/render` (arborium's tree-sitter grammars, bundled JetBrains Mono), run as a supervised `run` job. `native/render/install.sh` builds it into `priv/bin`; `PATH` also works. a language without a compiled-in grammar renders unhighlighted. the same binary renders snapcompact frames and fits oversized history images to a provider's edge (`--fit`, see [models](models.md)); every daemon call goes through `albedo_render.erl`.

## work

`work` is a revision-checked ledger shared by humans and agents. The model uses `await work.list/get/create/update/delete`. People use `/work`, its page: `a` adds an item, `e` renames, `d` marks done, `s` sets a status, and `x` removes one (an item with sub-items stays). Typed forms work too: `/work add <title>`, `/work edit <id> <title>`, `/work status <id> <status>`, `/work remove <id>`. Every change a person makes is queued as a note for the agent. Open items appear beside the conversation when the terminal is wide enough.

## files

see [the files extension](files.md): bounded reads, guarded exact edits, and ripgrep search that runs as a supervised `run` job instead of a raw subprocess.

## models

see [the models catalog](models.md): the cached models.dev catalog that supplies context windows, modalities, and provider endpoints to compaction and `/context`.

## commands

see [the commands extension](commands.md) for the full contract. `CommandPlugin` contributes static commands and `Managed.commands` dynamic ones; runs execute outside the session actor and reach state only through the registered state seam.

## mcp

see [the mcp extension](mcp.md) for connecting Model Context Protocol servers: configuration, credential scope, namespaced tools, and connection lifecycle.

## webhooks

Optional. A signed HTTP hook wakes one persistent session, with an opt-in setting for agent self-management. See [webhooks](webhooks.md) for setup, signing, retries, and security boundaries.

## remote

the `remote` extension boots this session's Python kernel on a remote host over one SSH connection, so every harness tool is callable on it, and it is enabled by default. `rem = await remote.connect()` stages albedo's python bundle on the target, starts the kernel there through SSH with `ControlMaster`/`ControlPersist` (one multiplexed TCP connection: no re-authentication per call), and answers the remote kernel's host-route calls against this session's daemon.

machine tools run on the remote kernel: `rem.run(program, *args)` starts a supervised job on the host immediately and synchronously, like local run — the handle exists right away, `job.tail()`, `job.id`, `job.exit_code`, `job.duration`, `job.waited`, and `job.timed_out` answer synchronously from the mirrored output stream, `await job` waits for completion, and `await job.stop()` stops it. pipes run entirely on the host, chained before the one await: `job = await rem.run("journalctl", "-u", "nginx", "--no-pager").pipe("rg", "error")`, then `job.tail(lines=40)`. `tail(lines=)` and `exit_code` answer from the mirror; other job methods, like `head(lines=)`, are remote calls to await, and properties such as `job.pipeline` do not cross. session tools run where the daemon runs: `await rem.work.*` and `await rem.skills.*` relay over the connection to the local daemon's ledger and catalog. both kernels load the same content-hashed bundle, so a tool's remote shape matches its local one. every other call returns a reference that settles on its first await: values cross as real objects — dataclasses and list subclasses are rebuilt, so remote output prints exactly like local output — and a result that cannot cross comes back as a live reference whose methods are further remote calls. references passed back into remote calls stay references, not copies, including ones still in flight. one rule remains: a call whose local counterpart is synchronous (`rem.files.read`) still needs `await`, because the value itself crosses the network; handles and their state never do.

images are the exception to "every harness tool runs remotely": a remote call is not a cell, so the remote kernel has no result to carry one. `await rem.show_image(path_or_bytes)` runs locally instead: it reads a remote path over the control connection (at most one byte past the 5 MiB a cell may carry) and attaches the bytes to the local cell through `api.attach_image`, so the image meets the same format, count, size and edge checks as `show_image`. it works in degraded mode too.

the target resolves per call from a `host=` argument, then `remote.configure(host, remote_cwd=None)`, then `$ALBEDO_SSH` (`user@host[:/path]`), then the `remote` section of extensions.json:

```json
{
  "remote": { "host": "deploy@box", "remoteCwd": "/srv/app", "python": "python3" }
}
```

a bare host asks the remote for its `pwd` once. if the host is reachable but its kernel cannot boot (no python, staging failed, bad handshake), `connect()` still returns and prints a warning: the connection is degraded to SSH command mode, where only `rem.run(program, *args, cwd=, env=, stdin=, timeout=300)`, `rem.shell(command, cwd=, env=, stdin=, timeout=300)`, `rem.read(path)`, `rem.write(path, content)`, and `rem.show_image(path_or_bytes)` answer and everything else raises. here `stdin` accepts only text or bytes, not a file or another job, and `.pipe()` is unavailable. The connect warning shows the degraded-only escape hatch `rem.shell('git log --oneline | rg fix')`, which invokes `bash -c` on the host for pipes or other shell syntax. `rem.shell()` does not exist in kernel mode. Neither the quoted-argv `rem.run()` fallback nor `rem.shell()` can offer process-group supervision, so stopping or timing out an ssh client does not prove the remote program stopped. an unreachable host fails `connect()`. connections are scoped: a lost SSH channel invalidates the connection rather than silently reconnecting, and `await rem.close()` ends it. connections run under `BatchMode=yes`, so key-based auth is required.

## skills

see [the skills extension](skills.md) for discovery paths, metadata-only startup context, and on-demand reading of actual `SKILL.md` files and resources. skills requires python: every cataloged skill is a [session command](commands.md) with a typed `commands.<method>(...)` binding, while users invoke the listed slash command. both resolve the same session catalog and the same activation. the model caller receives instructions as data without submitting another turn; the user caller submits one activation turn. installing or reading a skill does not run its scripts or import its code automatically.

## rolling compaction

`rolling` is the enabled-by-default compaction strategy: summary, recent-user recap, then a verbatim tail, triggered by remaining context. see [compaction](compaction.md) for its contract, settings, and state handling.

## snapcompact

`snapcompact` is an alternative compaction strategy: evicted history as rendered bitmap frames under per-provider image budgets. it requires `snapcompact-memory`, which is enabled by default, keeps the archive readable as text folds after a switch, and provides `transcript_grep` and `transcript_read`. see [compaction](compaction.md).

## lcm compaction

`lcm` is an alternative compaction strategy with source-backed hierarchical summaries. enabling it disables `rolling` in the same reload. `lcm-memory` keeps `lcm_list`, `lcm_grep`, `lcm_describe`, and `lcm_expand` available after a switch back to `rolling`, so stored folds remain accessible even if a rolling summary omits them. see [compaction](compaction.md) for the handoff and retrieval limits.
