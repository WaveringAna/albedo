# agents.md

The project is albedo. It is a coding agent daemon written in Gleam on the BEAM, with a detachable native CLI in Go (Charm: bubbletea, lipgloss, bubbles). The daemon owns everything: sessions (each one an actor over a durable, append-only SQLite transcript), the model/tool loop, the provider transport, the extensions that contribute tools and context, and a persistent Python kernel the model drives through cells. The CLI is a thin client: it finds or starts the daemon, then renders. The daemon also serves a local HTTP API that webhooks, the orchestrator view, and the test suites use.

In a checkout the CLI starts the daemon with `gleam run` (entry: `src/albedo.gleam` -> `albedo/daemon/server`). An installed binary launched outside the checkout needs `ALBEDO_ROOT` pointed at the repo to start a daemon; `./cli/bin/albedo` finds the root on its own, and a packaged daemon can be swapped with `ALBEDO_DAEMON`. Secrets and caches live in `$ALBEDO_HOME` (default `~/.albedo`).

### Tooling rules

The package manager is gleam. Please when you want to add a package, which is never unless told to, do `gleam add ...` (dev deps: `gleam add --dev ...`), please do not try to edit `manifest.toml` yourself. Gleam generates it.

PLEASE USE `gleam check` to type check and `gleam format src test` to format Gleam. Python is formatted with `ruff format priv/python test`. `nix develop` puts ruff on PATH; outside it, install the version `.pre-commit-config.yaml` pins with `uv tool install ruff==0.13.3` (or run it once with `uvx ruff@0.13.3 format priv/python test`), since the hook's own copy lives inside pre-commit's cache and is not on PATH. `pre-commit run --all-files` formats the whole repository, and the commit hook re-formats staged Gleam and Python files.

For Go changes, run gopls with `staticcheck` and all available analyses enabled, alongside vet and tests. Fix diagnostics by simplifying the code, without adding wrappers or obscuring control flow.

- Gleam suites: `gleam test`
- Go: `go -C cli vet ./...` and `go -C cli test ./...`
- Rust (optional `view` renderer): `cargo test --release --locked --manifest-path native/render/Cargo.toml`
- Everything that must pass before a commit: `./test.sh`

Anything that opens a browser must set `ALBEDO_NO_BROWSER=1`; `test.sh` exports it for the whole gate.

### Test layout and the build lock

`./test.sh` is the gate. The quick checks run first, in order (format check, cargo test + renderer install, Go vet, the CLI build the Python e2e suite drives); then it compiles the daemon once and runs every suite at the same time (`gleam test`, each `test/harness/*_test.py`, Go unit tests, the Go e2e suite, the Python e2e suite), each into its own log, printed only when that suite fails.

The e2e suites compile the daemon once per run with `test/snapshot-daemon.sh` (test.sh does it once for both and passes `ALBEDO_TEST_DAEMON`) and boot every test daemon from that copy through `ALBEDO_DAEMON`, never through `gleam run`, so their daemons neither queue on gleam's build lock nor see a rebuild mid-run. The one compile still takes the lock, which `gleam test` holds for its whole run: an e2e suite started from inside `gleam test` deadlocks, and one started beside it waits for it to finish. The Python e2e suite drives the prebuilt `cli/bin/albedo` binary; the Go e2e suite builds its own CLI and runs with `-count=1`, because it boots a hermetic daemon and must never reuse a cached run or a stale binary.

Test placement (expanded rules in `.agents/skills/writing-tests/SKILL.md`): the default is an end-to-end scenario through the real daemon on the shared harness in `test/e2e/` — a scripted fake model provider, one shared daemon for the tests that isolate themselves by session, workspace and provider profile, and a fresh daemon for each `@exclusive` test that changes global state or restarts it. Unit tests are the exception; each module docstring must say which bug it catches that E2E cannot. `test/harness/api_docs_test.py` is the invariant test to imitate: it builds the model's real Python namespace and fails whenever a public binding exists that the model is never told about. `test/manual/` is opt-in (needs a provider, a PTY, or benchmark artifacts) and is never part of the gate.

### `src/` — the daemon (Gleam)

- **`src/albedo/daemon/`** — session actors and durable state: submission/run/turn plumbing (`session_*.gleam`), the append-only transcript and conversation store (SQLite via sqlight), the event bus, projections, the family (agents, mail, bus), folders, quota, usage, the reaper, persisted settings, the image store, and `server.gleam`, the HTTP entry point.
- **`src/albedo/daemon/migrations/`** — existing SQLite upgrades, with ordered startup data steps in `daemon/migrations.gleam`; schema additions remain called from owning initialisers (see `robot-docs/migrations.md`).
- **`src/albedo/harness/`** — the model-facing half: `loop.gleam` (the tool loop), `tool.gleam`, `extension.gleam` and `extensions.gleam` (plugin interfaces and composition), `compaction.gleam`, `runtime.gleam` (boots the built-ins), plus credentials, oauth, rotation, session settings mutations, shared settings persistence, extension settings, and the usage feed.
- **`src/albedo/harness/extensions/`** — one directory per extension. Enabled by default: `python`, `run`, `work`, `mail`, `agents`, `schedule`, `paperclips`, `files`, `memory`, `instructions`, `commands`, `skills`, `models`, `openai`, `codex`, `antigravity`, `alibaba`, `claude`, `rolling`, `snapcompact-memory`, `lcm-memory`, `remote`, `browser`. Installed but off until enabled: `mcp`, `view`, `proxy`, `webhooks`, `warm`, `snapcompact`, `lcm`. The provider extensions are ordered before `models` on purpose (their own model lists win), and the memory/compaction pairs are ordered so archives cover past folds.
- **`src/albedo/openai_api/`** — the provider transport every extension shares: request/turn types, SSE framing, stream reducers, replay after restarts, chat/responses encodings. A provider with a foreign wire format encodes an `openai_api.Exchange` and supplies only its own reducer (antigravity does this); HTTP, retries, limits, and callbacks stay shared.

The extension record is the core abstraction everything composes through:

```gleam
extension.Extension(
  name: "project-context",
  description: "workspace instructions for the model",
  requires: [],
  plugins: [extension.ContextPlugin(load: load_workspace_context)],
  initialise: fn(_) { Ok(Nil) },
)
```

An extension bundles plugins: context (system instructions), tool (model tools + Python modules + host routes), command (one definition drives the CLI menu, user invocation, and the kernel's typed `commands` bindings), managed (stateful contributions that observe session events), models/model-provider (catalog, wire protocol, login), service (HTTP under `/<extension>/`), migration (extension-owned SQLite upgrades applied by the host), compaction, and fold. Selection is per session through `/extensions`; at most one compaction strategy may be enabled, and changes require an idle session.

### `cli/` — the terminal (Go)

- **`cli/cmd/albedo`** — production wiring, project-root discovery, and final error reporting
- **`cli/internal/cli`** — Cobra constructors, strict argument validation, and command rendering
- **`cli/internal/app`** — typed session, prompt, model, and daemon workflows with lazy connections
- **`cli/internal/terminal`** — TTY detection, confirmation, migration notices, and Bubble Tea launch
- **`cli/internal/storage`** — offline usage inspection and approved cleanup plans with revalidation
- **`cli/internal/config`** — connection home, settings value types, and immediate form validation
- **`cli/internal/daemon`** — daemon lifecycle (find or start, auth token) and the typed API client
- **`cli/internal/tui`** — the bubbletea UI: chat, model picker, orchestrator view, page screens, forms
- **`cli/test/e2e`** — the Go e2e suite against the real binary and a hermetic daemon

### `priv/` and `native/`

- **`priv/python/`** — the actual Python kernel: `albedo_kernel.py` (cell execution, persistent namespace), `albedo_proc.py`/`albedo_shell.py` (run jobs), `albedo_api.py`, `albedo_trace.py`, and `albedo_plugins/`. The daemon boots this per session; changes apply to new kernels.
- **`priv/linguist/`** — GitHub's language data for file detection (`harness/languages.gleam`)
- **`priv/cache-ttl.json`** — the prompt-cache TTL prior table (see `robot-docs/cache-ttl.md`)
- **`native/render/`** — optional Rust renderer behind the `view` extension, which shows the model its changes as highlighted images for the final review pass. Install with `native/render/install.sh`; needs cargo.

### robot-docs/

`robot-docs/` is one model-facing doc per subsystem (agents, auth, settings, migrations, cache-ttl, cache-warming, commands, compaction, context, extensions, files, mcp, models, paperclips, provider-requests, proxy, quota, skills, usage-feed, webhooks, workspaces). This file is the map; those are the details. When you change a subsystem's behavior, update its doc in the same change; when you need to understand one, read it there first.

### Other directories

- **`test/`** — `e2e/` (default suite, shared harness), `harness/` (invariant and logic unit tests, Gleam and Python), `daemon/` (Gleam daemon suites), `openai_api/` (transport), `manual/` (opt-in)
- **`flake/`**, **`default.nix`** — nix packaging and dev shell (`nix develop` ships gleam, go, cargo, python, and pre-commit); `nix build .#albedo` produces a self-contained package
- **`.agents/skills/`** — repo-local agent skills (`writing-tests`, `charm-tui`, `gleam-design`, `tg`, `orchestrating-agents`)
