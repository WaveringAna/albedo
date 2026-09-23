# albedo

small gleam coding and (not yet) persistent agent daemon with a detachable cli

- python repl and bash.
- native go cli using charm (bubbletea, lipgloss, bubbles)

```sh
# build native go cli
go -C cli build -o bin/albedo ./cmd/albedo
./cli/bin/albedo

# or to install it globally
go -C cli install ./cmd/albedo
albedo
```

when installed globally outside the checkout, set `ALBEDO_ROOT` to the absolute repo path if the daemon needs to be started:
```sh
ALBEDO_ROOT=/path/to/albedo albedo
```
`ALBEDO_ROOT` is only needed when the installed binary needs to launch the daemon from outside the repo tree; the local binary (`./cli/bin/albedo`) discovers the repo root automatically from its file path. you can also embed the root at build/install time if preferred:
```sh
go -C cli install -ldflags "-X main.buildRoot=$(pwd)" ./cmd/albedo
```

nix package (includes the compiled daemon and python runtime):

```sh
nix build .#albedo
nix run . -- --help
# package checks, with a local mock provider (no model credentials):
python3 test/manual/nix_package_smoke.py "$PWD/result/bin/albedo"
ALBEDO_NO_BROWSER=1 ALBEDO_TEST_BINARY="$PWD/result/bin/albedo" python3 test/daemon/integration.py
```

`default.nix` is also available through `pkgs.callPackage ./default.nix { }`.
no checkout or gleam compiler is needed at runtime. `ALBEDO_DAEMON` can override
the packaged daemon with an absolute executable path.

legacy typescript reference (kept for parity testing):

```sh
npm --prefix cli install
# ALBEDO_USE_TS=1 forces the launcher to use the TypeScript reference instead of native binary
ALBEDO_USE_TS=1 node cli/bin/albedo.mjs

# or to install it globally via npm
npm install -g ./cli
ALBEDO_USE_TS=1 albedo
```

optional: `view`, which lets the model see its changes and code as highlighted
images for a final review pass. needs cargo.

```sh
native/render/install.sh   # then enable `view` in /extensions
```

tests

```sh
./test.sh               # gleam, native go cli, and daemon suites
go -C cli test ./...    # native go cli tests
go -C cli vet ./...     # native go cli vet
gleam test              # gleam suite plus the python harnesses that hold no build lock
```

manual comparisons and performance tools:

`test/manual` is opt-in: those benchmarks need a provider, a PTY, or artifacts
from an earlier run.

```sh
# paired TS/Go screenshots (Pillow via uv; npm dependencies from cli)
uv run --no-project --script cli/test/manual/visual_parity.py --help

# standalone PTY smoke and parity verification
ALBEDO_NO_BROWSER=1 python3 test/manual/go_port_smoke.py

# 120Hz scrollback performance and timing evaluation
ALBEDO_NO_BROWSER=1 python3 test/manual/go_scroll_perf.py

# native heap and runtime memory attribution profile
ALBEDO_NO_BROWSER=1 python3 test/manual/go_memory_profile.py
```

todo
- [] flesh out plugin system more
- [] sdk and -p, command to print out most recent assistant message from session
- [] compaction strategy plugins LCM and snapcompact
- [] compaction evaluations: old-fact recall, corrected instructions, tool pairing, images, restarts, and token/cost comparisons
- [] subagents plugin
- [] social plugins like discord
- [ish skills are done] plugins like heartbeat and skills
- [] oauth that we shamelessly rip from omp
- [] ai powered approve for me (jev/llm)
- [] improve verbose mode on tui
- [] webui
- [] connect to other albedos on tui/webui and manage sessions
- [] ability to offload tools like python/bash onto other machines/containers
