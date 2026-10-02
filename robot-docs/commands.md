# commands

every session command is one definition with three faces: the CLI menu, user invocation, and the model's typed `commands` bindings. adding a command adds all three; nothing about a command is reimplemented per surface.

## the catalog

`GET /sessions/:id/commands` lists the materialized catalog: name (the slash spelling), description, the minted python `method`, its `usage` line, declared `arguments`, and the `modelCallable`, `userTurn`, and `skill` flags. The `skill` flag marks a selected skill with a preparation function. The CLI submits these through the durable events route. Other command handlers keep their existing uncertainty policy. The CLI menu renders the catalog, merged with its presentation-only entries like `/login` and `/sessions`. The list mints the kernel bindings at boot, and the prompt's `<session_commands>` block summarizes it.

`POST /sessions/:id/commands` runs one command. the body is `{name, arguments}` with raw invocation text (`{"name": "/model", "arguments": "gpt-5 anthropic"}`) or `{name, args}` with declared names (`{"name": "/model", "args": {"model": "gpt-5"}}`); `clientId` labels a submitted turn. the answer is `{"result": ...}` with the command's JSON value or `{"submitted": true}` when a user invocation submitted its turn.

The Go client returns `daemon.APIError` for HTTP failures, retaining the status, daemon error code, and message. Use `errors.As` to inspect it. Workspace failures also unwrap to `daemon.WorkspaceMissingError` so the chat can offer a replacement folder. Capability checks return `daemon.UpgradeRequiredError`; the TUI recognizes that type when displaying catalog upgrade failures. Error wording does not control this routing.

## contributing commands

`CommandPlugin` in an extension declares static commands; a `ManagedPlugin` contributes dynamic ones through `Managed.commands` (this is how skills registers its slash commands). the type lives in [`command.gleam`](../src/albedo/harness/command.gleam):

```gleam
Command(
  "/usage",
  "Show token and cost usage for this session",
  [Argument("window", "reporting window", False)],
  True,
  False,
  False,
  None,
  fn(context, _caller, args) { ... Ok(command.Data(value)) },
)
```

a run executes **outside** the session actor — on the kernel's host-call process or an HTTP request process — and reaches session state only through `Context.state`, whose operations are the `StateOp` variant type in [`command.gleam`](../src/albedo/harness/command.gleam) (the exhaustive case in `session.gleam` answers them). a handler running inside the session actor must never run a command: its state calls would deadlock against itself.

`model_callable: False` keeps a command user-only (`/login`-class commands). a `user_turn: True` command submits its outcome as one user turn when a user invokes it and returns data when the model invokes it — one run, two callers, only the delivery differs. dispatch refuses a model invocation of a user-only command and refuses any turn submission from the model.

## python bindings

the `commands` extension exposes the async `commands` object. at kernel boot the catalog mints one typed method per model-callable command: `commands.model("gpt-5")`, `commands.demo("the args")`. each method's docstring and signature come from the declaration, so `help(commands.<method>)` is the command's help text. `commands.catalog()` returns the current catalog, so a session `/reload` reaches it without a kernel restart; `commands.invoke(name, arguments)` runs any model-callable command by slash name with raw text or a dict. a command whose method name is reserved (`catalog`, `invoke`, `help`), invalid, taken, or added after the kernel booted stays callable through `invoke()`.

argument parsing is shared: leading arguments take one whitespace token each, the last declared argument takes the rest with outer whitespace trimmed and inner spacing exact, so `/fix-lint one  two` arrives as `"one  two"`.

## v1 commands

- `/model [model] [provider] [effort]` — show the selection (any caller) or switch it (user only, idle session; a model call is always mid-turn, so switching is refused and the model is told to ask the user). A given effort must be one the new model supports; without one, the current effort carries over when the new model supports it.
- `/context [section] [page]` — the prepared model request: a summary, or one bounded section page.
- `/raise-cap [on|off] [model]` — raise a model's context window to the provider's maximum, or restore its default (user only). Without a state it toggles; without a model it uses the session's. The choice is saved per model in `raisedCaps` and applies to every session on that model from its next request. See [raised caps](models.md#raised-caps).

the python extension contributes `/kernel [upgrade]` — whether the session's kernel runs older code than the daemon (bundle, module set, or protocol) and what keeps it, or, with `upgrade` (user only, between turns), swap it now past its live jobs (`KernelReport` / `KernelUpgrade` state ops). See [kernel](kernel.md#version-skew).

the links extension contributes `/link [add|remove] [workspace]` — the workspaces linked with this one, as a page (`here`, `gone` for a member whose folder is missing, checked on its host for a remote one, or why the host can't say), or, user only, link one or unlink one; every open session in the workspaces it touches gets a note either way. See [workspaces](workspaces.md#linked-workspaces).

skills contributes one command per cataloged skill; `/tree`, `/fork`, `/login`, and the other picker-style entries stay presentation-only in the CLI.

## CLI page lifecycle

`cli/internal/tui/page.go` allocates a unique generation for each page instance and each superseding request. Generic pages, capability pages, extension pickers, tree pickers, context inspectors, and webhook pages reject responses from earlier generations before changing data or operation state. A delayed tree-fork completion also carries its generation to the app.

The app forwards history and context-window responses to the active chat while a modal is open. Chat checks the session and generation before accepting them. Generic page text and secret inputs receive paste and cursor messages while focused, including the input component's returned command.
