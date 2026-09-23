# albedo

small gleam coding and (not yet) persistent agent daemon with a detachable cli

- python repl and bash.
- cli for now is ink based 

```sh
npm --prefix cli install
node cli/bin/albedo.mjs

# or to install it globally

npm install -g ./cli
albedo
```

optional: `view`, which lets the model see its changes and code as highlighted
images for a final review pass. needs cargo.

```sh
native/render/install.sh   # then enable `view` in /extensions
```

tests

```sh
./test.sh          # gleam, cli, and daemon suites
gleam test         # gleam suite plus the python harnesses that hold no build lock
```

`test/manual` is opt-in: those benchmarks need a provider, a PTY, or artifacts
from an earlier run.

todo
- [] flesh out plugin system more
- [] sdk and -p, command to print out most recent assistant message from session
- [] compaction strategy plugins LCM and snapcompact
- [] compaction evaluations: old-fact recall, corrected instructions, tool pairing, images, restarts, and token/cost comparisons
- [] subagents plugin
- [] social plugins like discord
- [] plugins like heartbeat and skills
- [] oauth that we shamelessly rip from omp
- [] ai powered approve for me (jev/llm)
- [] improve verbose mode on tui
- [] webui
- [] connect to other albedos on tui/webui and manage sessions
- [] ability to offload tools like python/bash onto other machines/containers
