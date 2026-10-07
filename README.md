# Overview (pre-alpha)

![albedo in a terminal](docs/screenshot.png)

Albedo is an agentic coding harness that can act on your device and soon able to manage sessions on other devices with agents that can act remotely on different machines or within containers. Our hope is that it being built on BEAM allows it to maintain low memory usage while running many concurrent agents and subagents across devices.

It is daemonized with the CLI and (future) WebUI being clients of this daemon. This ensures the agents can be programatically created, controlled, and even stopped all while still providing an experience similar to other harnesses like Claude Code and Codex. Albedo provides a Python REPL for the agents to use as a scratchpad and data manipulation allowing them to experiment, reason, and play with code before actually writing it down. This is similar to what other harnesses call CodeMode, and is based on [prime-agent's](https://github.com/PrimeIntellect-ai/prime-agent/)'s Python REPL and design.

The CLI is written in Go and uses the Charm stack. 

```sh
# build native go cli
go -C cli build -o bin/albedo ./cmd/albedo
./cli/bin/albedo

# or to install it globally
go -C cli install ./cmd/albedo
albedo
```

When installed globally outside the checkout, set `ALBEDO_ROOT` to the absolute repo path if the daemon needs to be started:
```sh
ALBEDO_ROOT=/path/to/albedo albedo
```
or embed the root at install time:
```sh
go -C cli install -ldflags "-X main.buildRoot=$(pwd)" ./cmd/albedo
```

The default Nix package includes the client, compiled server, Python runtime, and Chrome Headless Shell for browser automation. The development shell also includes the browser:

```sh
nix build .#albedo
nix run . -- --help
# package checks, with a local mock provider (no model credentials):
python3 test/manual/nix_package_smoke.py "$PWD/result/bin/albedo"
ALBEDO_NO_BROWSER=1 ALBEDO_TEST_BINARY="$PWD/result/bin/albedo" python3 test/daemon/integration.py
```

The client and server also build separately:

```sh
nix build .#albedo-client --out-link result-client
nix build .#albedo-server --out-link result-server
ALBEDO_DAEMON="$PWD/result-server/bin/albedo-daemon" ./result-client/bin/albedo
```

optional: `view`, which lets the model see its changes and code as highlighted
images for a final review pass. needs cargo.

```sh
native/render/install.sh   # then enable `view` in /extensions
```

## CLI usage

Run `albedo` to open the terminal interface, or use `--prompt` to print a reply:

```sh
albedo -p "Explain this project"
albedo --prompt "Run the checks" --session SESSION_ID --timeout 10m
albedo resume SESSION_ID
albedo sessions --json
albedo sessions read SESSION_ID 3      # the newest 3 turns (default 1); --json for structure
albedo sessions send SESSION_ID "message"
```

Session IDs can be shortened to any unique prefix. Run `albedo --help` or
`albedo COMMAND --help` for command options.

To inspect disk usage without starting the daemon, run `albedo storage --json`
or `albedo storage --sessions`. Offline database inspection and cleanup use the
local daemon executable without starting its server. Set `ALBEDO_DAEMON` to a
packaged executable or `ALBEDO_ROOT` to a source checkout. These storage commands
do not require Python. To clean up local files, stop the daemon first:

```sh
albedo daemon --stop
albedo storage prune --backups
```

Cleanup shows a preview and asks for confirmation. To permanently delete sessions,
use `albedo storage prune --session SESSION_ID`, repeating `--session` for each
full ID. Add `--yes` to skip confirmation in scripts.

formatting

```sh
nix fmt                         # treefmt: Nix, Gleam, Go, Python, and shell files
pre-commit install              # once per checkout; available in `nix develop`
pre-commit run --all-files       # format, lint Python, and type-check Python
gleam format src test           # fix Gleam formatting
ruff format priv/python test    # fix Python formatting
ruff check                      # lint Python
ty check                        # type-check the kernel, plugins, and tests
```

The commit hook formats staged files and runs the Python checks; it needs
`gleam` on PATH.

tests

```sh
./test.sh               # gleam, native go cli, and daemon suites
go -C cli test ./...    # native go cli tests
go -C cli vet ./...     # native go cli vet
gleam test              # gleam suite
```

`test/manual` holds opt-in checks that need a packaged binary or real credentials.

todo
- [] flesh out plugin system more
- [] sdk and -p, command to print out most recent assistant message from session
- [✓] compaction strategy plugins LCM and snapcompact
- [] compaction evaluations: old-fact recall, corrected instructions, tool pairing, images, restarts, and token/cost comparisons
- [✓] subagents plugin
- [] social plugins like discord
- [✓] plugins like heartbeat and skills
- [ish] oauth that we shamelessly rip from omp
- [] ai powered approve for me (jev/llm)
- [] improve verbose mode on tui
- [] webui
- [] connect to other albedos on tui/webui and manage sessions
- [ish we have remote but model opts into it, not yet able to have the model natively act in a different machine] ability to offload tools like python/bash onto other machines/containers
