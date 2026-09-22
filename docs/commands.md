# commands

every session command is one definition with three faces: the CLI menu, user invocation, and the model's typed `commands` bindings. adding a command adds all three; nothing about a command is reimplemented per surface.

## the catalog

`GET /sessions/:id/commands` lists the materialized catalog: name (the slash spelling), description, the minted python `method`, its `usage` line, declared `arguments`, and the `modelCallable` / `userTurn` flags. the CLI menu renders it (merged with its presentation-only entries like `/login` and `/sessions`), `GET`'s list mints the kernel bindings at boot, and the prompt's `<session_commands>` block summarizes it. all three read the same list.

`POST /sessions/:id/commands` runs one command. the body is `{name, arguments}` with raw invocation text (`{"name": "/model", "arguments": "gpt-5 anthropic"}`) or `{name, args}` with declared names (`{"name": "/model", "args": {"model": "gpt-5"}}`); `clientId` labels a submitted turn. the answer is `{"result": ...}` with the command's JSON value or `{"submitted": true}` when a user invocation submitted its turn.

## contributing commands

`CommandPlugin` in an extension declares static commands; a `ManagedPlugin` contributes dynamic ones through `Managed.commands` (this is how skills registers its slash commands). the type lives in [`command.gleam`](../src/albedo/harness/command.gleam):

```gleam
Command(
  "/usage",
  "Show token and cost usage for this session",
  [Argument("window", "reporting window", False)],
  True,
  False,
  fn(context, _caller, args) { ... Ok(command.Data(value)) },
)
```

a run executes **outside** the session actor — on the kernel's host-call process or an HTTP request process — and reaches session state only through `Context.state`, whose operations are the `StateOp` variant type in [`command.gleam`](../src/albedo/harness/command.gleam) (the exhaustive case in `session.gleam` answers them). a handler running inside the session actor must never run a command: its state calls would deadlock against itself.

`model_callable: False` keeps a command user-only (`/login`-class commands). a `user_turn: True` command submits its outcome as one user turn when a user invokes it and returns data when the model invokes it — one run, two callers, only the delivery differs. dispatch refuses a model invocation of a user-only command and refuses any turn submission from the model.

## python bindings

the `commands` extension exposes the async `commands` object. at kernel boot the catalog mints one typed method per model-callable command: `commands.model("gpt-5")`, `commands.demo("the args")`. each method's docstring and signature come from the declaration, so `help(commands.<method>)` is the command's help text. `commands.catalog()` returns the immutable catalog; `commands.invoke(name, arguments)` runs any model-callable command by slash name with raw text or a dict. a command whose method name is reserved (`catalog`, `invoke`, `help`), invalid, or taken stays callable through `invoke()`.

argument parsing is shared: leading arguments take one whitespace token each, the last declared argument takes the rest with outer whitespace trimmed and inner spacing exact, so `/fix-lint one  two` arrives as `"one  two"`.

## v1 commands

- `/model [model] [provider]` — show the selection (any caller) or switch it (user only, idle session; a model call is always mid-turn, so switching is refused and the model is told to ask the user).
- `/context [section] [page]` — the prepared model request: a summary, or one bounded section page.

skills contributes one command per cataloged skill; `/tree`, `/fork`, `/login`, and the other picker-style entries stay presentation-only in the CLI.
