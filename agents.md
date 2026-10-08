# agents.md

The project is albedo. It is a coding agent daemon written in Gleam on the BEAM, with a detachable native CLI in Go (Charm: bubbletea, lipgloss, bubbles). The daemon owns everything: sessions (each one an actor over a durable, append-only SQLite transcript), the model/tool loop, the provider transport, the extensions that contribute tools and context, and a persistent Python kernel the model drives through cells. The CLI is a thin client: it finds or starts the daemon, then renders. The daemon also serves a local HTTP API that webhooks, the orchestrator view, and the test suites use.

In a checkout the CLI starts the daemon with `gleam run` (entry: `src/albedo.gleam` -> `albedo/daemon/server`). An installed binary launched outside the checkout needs `ALBEDO_ROOT` pointed at the repo to start a daemon; `./cli/bin/albedo` finds the root on its own, and a packaged daemon can be swapped with `ALBEDO_DAEMON`. Secrets and caches live in `$ALBEDO_HOME` (default `~/.albedo`).

### Tooling rules

The package manager is gleam. Please when you want to add a package, which is never unless told to, do `gleam add ...` (dev deps: `gleam add --dev ...`), please do not try to edit `manifest.toml` yourself. Gleam generates it.

PLEASE USE `gleam check` to type check and `gleam format src test` to format Gleam. Python is formatted with `ruff format priv/python test`, linted with `ruff check`, and type-checked with `ty check`. Both checks cover `priv/python` and all Python files in `test`, including manual tools; settings live in `pyproject.toml`. Ruff, ty, and Pyright target Python 3.11. The Nix development shell and packaged daemon use Python 3.11, Erlang/OTP 29, and Gleam 1.19 (`gleam.toml` requires it: 1.18's formatter rejects 1.19's output); the daemon needs OTP 29 (its HTTP layer uses `zstd`, including `zstd:flush`). `nix develop` puts Ruff and ty on PATH. Outside it, use `uvx ruff@0.16.10 check` and `uvx ty@0.0.84 check`, matching the pre-commit pins. `pre-commit run --all-files` formats Gleam and Python, checks Python lint, and runs ty across the project. The commit hook formats staged files and runs both Python checks. `nix fmt` also applies Ruff lint fixes.

For Go changes, use the Go and gopls supplied by `nix develop` (they come from the same pinned nixpkgs snapshot); do not mix a host gopls with a newer Go toolchain. Run gopls with `staticcheck` and all available analyses enabled, alongside vet and tests. Fix diagnostics by simplifying the code, without adding wrappers or obscuring control flow.

- Gleam lint: `test/gleam-lint.sh` (pinned glinter in `nix develop`; eleven focused rules also run in pre-commit and `test.sh`; manual review and audit profiles are documented in `robot-docs/gleam-lint.md`)
- Keep generated lint reports under `/tmp`. Never commit CSV audit inventories or retrospective cleanup reports.
- Gleam suites: `gleam test`
- Go: `go -C cli vet ./...` and `go -C cli test ./...`
- Rust (optional `view` renderer): `cargo test --release --locked --manifest-path native/render/Cargo.toml`
- Everything that must pass before a commit: `./test.sh`

Anything that opens a browser must set `ALBEDO_NO_BROWSER=1`; `test.sh` exports it for the whole gate.

### Test layout and the build lock

`./test.sh` is the gate. The quick checks run first, in order (Ruff lint and format checks, ty, Gleam format and lint checks, cargo test + renderer install, Go vet, the CLI build the Python e2e suite drives); then it compiles the daemon once and runs every suite at the same time (`gleam test`, each `test/harness/*_test.py`, Go unit tests, the Go e2e suite, the Python e2e suite), each into its own log, printed only when that suite fails.

Python test files are loaded through `test/python_test_runner.py`; a selected file with no unittest cases fails. The E2E runner also rejects an empty aggregate before boot. Gleam and Erlang discovery selects `_test` files with exported test functions or generators, excluding the `albedo_test.gleam` entrypoint and manual tools. Support modules remain compiled but are not suites. Put reusable Python fixtures in `_support.py` modules. Inspection transport belongs to `test/e2e/inspect_support.py`; probes use the typed session diagnostics described in `robot-docs/runtime.md`.

The e2e suites compile the daemon once per run with `test/snapshot-daemon.sh` (test.sh does it once for both and passes `ALBEDO_TEST_DAEMON`) and boot every test daemon from that copy through `ALBEDO_DAEMON`, never through `gleam run`, so their daemons neither queue on gleam's build lock nor see a rebuild mid-run. The one compile still takes the lock, which `gleam test` holds for its whole run: an e2e suite started from inside `gleam test` deadlocks, and one started beside it waits for it to finish. The Python e2e suite drives the prebuilt `cli/bin/albedo` binary; the Go e2e suite builds its own CLI and runs with `-count=1`, because it boots a hermetic daemon and must never reuse a cached run or a stale binary.

Test placement (expanded rules in `.agents/skills/writing-tests/SKILL.md`): the default is an end-to-end scenario through the real daemon on the shared harness in `test/e2e/` — a scripted fake model provider, one shared daemon for the tests that isolate themselves by session, workspace and provider profile, and a fresh daemon for each `@exclusive` test that changes global state or restarts it. Unit tests are the exception; each module docstring must say which bug it catches that E2E cannot. `test/harness/api_docs_test.py` is the invariant test to imitate: it builds the model's real Python namespace and fails whenever a public binding exists that the model is never told about. `test/manual/` is opt-in (needs a provider, a PTY, or benchmark artifacts) and is never part of the gate.

### Committing and pushing

Other sessions and agents often work in this checkout at the same time. Stage only the paths you changed (`git add -- <paths>`), leave other files alone, and never stash someone else's changes.

If "push" could mean `main`, a branch, or a pull request, ask which before pushing.

A push that fails with tangled's `too many concurrent operations from your address` is a rate limit, not a rejection: retry after about 15 seconds.

### `src/` — the daemon (Gleam)

- **`src/albedo/daemon/`** — session actors and durable state: submission/run/turn plumbing (`session_*.gleam`), the append-only transcript and conversation store (SQLite via sqlight), the event bus, projections, the family (agents, mail, bus), folders, quota, usage, the reaper, persisted settings, the image store, and `server.gleam`, the HTTP entry point, whose listener runs under `listener.gleam`: a listener tree that gives up is restarted with backoff on the same port, so the daemon outlives it.
- **`src/albedo/daemon/migrations/`** — existing SQLite upgrades, with ordered startup data steps in `daemon/migrations.gleam`; schema additions remain called from owning initialisers (see `robot-docs/migrations.md`).
- **`src/albedo/harness/`** — the model-facing half: `loop.gleam` (the tool loop), `tool.gleam`, `extension.gleam` (plugin interfaces, installation), `extension/composition.gleam` and `extension/selection.gleam` (a session's composed plugins; its saved selection), `extensions.gleam` (the built-in list), `compaction.gleam`, `runtime.gleam` (the runtime actor's public api and message loop; its state, scheduler, kernel plumbing, preparation, reload, and upgrade live under `runtime/`), plus credentials, oauth, rotation, session settings mutations, shared settings persistence, extension settings, and the usage feed.
- **`src/albedo/harness/extensions/`** — one directory per extension. Enabled by default: `python`, `run`, `work`, `mail`, `agents`, `schedule`, `paperclips`, `files`, `memory`, `links`, `instructions`, `commands`, `skills`, `models`, `openai`, `codex`, `antigravity`, `alibaba`, `bedrock`, `claude`, `vertex`, `rolling`, `snapcompact-memory`, `lcm-memory`, `notes`, `remote`, `browser`, `warm`, `exa`, `web-search`. Installed but off until enabled: `mcp`, `view`, `proxy`, `webhooks`, `snapcompact`, `lcm`. The provider extensions are ordered before models.dev on purpose (their own model lists win), and the memory/compaction pairs are ordered so archives cover past folds.
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
- **`cli/internal/tui`** — the bubbletea UI: chat, model picker, orchestrator view, page screens, forms (list screens share one frame, filter, confirm and key set; see `robot-docs/tui.md` before adding or changing one)
- **`cli/test/e2e`** — the Go e2e suite against the real binary and a hermetic daemon

### `priv/` and `native/`

- **`priv/python/`** — the actual Python kernel: `albedo_kernel.py` (the entry point) and `albedo_cells.py` (cell execution, persistent namespace), `albedo_proc.py`/`albedo_shell.py` (run jobs), `albedo_api.py`, `albedo_trace.py`, and `albedo_plugins/`. The daemon boots this per session; changes apply to new kernels.
- **`priv/linguist/`** — GitHub's language data for file detection (`harness/languages.gleam`)
- **`priv/cache-ttl.json`** — the prompt-cache TTL prior table (see `robot-docs/cache-ttl.md`)
- **`native/render/`** — optional Rust renderer behind the `view` extension, which shows the model its changes as highlighted images for the final review pass. Install with `native/render/install.sh`; needs cargo.

### robot-docs/

`robot-docs/` is one model-facing doc per subsystem (agents, auth, settings, kernel-state, migrations, cache-ttl, cache-warming, commands, compaction, context, extensions, files, kernel, mcp, models, paperclips, provider-requests, proxy, quota, runtime, shims, skills, tui, usage-feed, web-search, webhooks, workspaces). This file is the map; those are the details. When you change a subsystem's behavior, update its doc in the same change; when you need to understand one, read it there first.

Shared clock, Unicode scalar, zero-copy shared value, and native-boundary rules live in `robot-docs/runtime.md`. Read it before adding runtime helpers, passing a catalog between processes, or moving logic across the Gleam/Erlang boundary.

Read the page for a subsystem before you edit it, and name the module that owns the behavior before you write it. Ownership rules live in those docs (an extension owns its own migrations and tables; the daemon only collects them), and the mistakes that cost the most were ones a doc already ruled out. Use the `design-preflight` skill for anything beyond a small change.

### Other directories

- **`test/`** — `e2e/` (default suite, shared harness), `harness/` (invariant and logic unit tests, Gleam and Python), `daemon/` (Gleam daemon suites), `openai_api/` (transport), `manual/` (opt-in)
- **`flake/`**, **`default.nix`** — nix packaging and dev shell (`nix develop` ships gleam, go, cargo, python, and pre-commit); `nix build .#albedo` produces a self-contained package
- **`.agents/skills/`** — repo-local agent skills (`writing-tests`, `charm-tui`, `gleam-design`, `tg`)
- **`priv/skills/`** — skills shipped with albedo (`customize-albedo`, `research`, `orchestrating-agents`, `complexity-review`, `design-preflight`); a same-named skill in a project or home directory replaces one
