# Daemon attachment and local startup

Albedo's API connection and its local process launcher have separate jobs. A
client can attach to a supplied endpoint without reading local installation
files, starting a process, or replacing one.

## Connection flow

1. `Discover` reads the local record and probes its authenticated `/server` resource.
   It reports absence, a proven stale record, or a running daemon. Invalid records,
   authentication failures, unreachable endpoints, and unhealthy daemons return
   actionable errors. A failed health check does not authorize another launch.
2. `Attach` validates the protocol and required capabilities, then returns an API
   connection. Build identity is update information. A different build with the
   required API remains usable.
3. The ordinary interactive CLI offers to restart a running daemon when the
   candidate build may differ from the running one: the content digests decide
   when both sides hashed their code trees, the build labels otherwise, and an
   unprovable comparison keeps the offer. Proven sameness attaches without
   asking. Keeping the daemon is the default. The prompt warns that restarting
   interrupts active work across sessions. Scripts keep a compatible daemon and
   report incompatibility instead of replacing it.
4. `Launch` starts a local daemon only under the application's policy. Concurrent
   launchers coordinate through a persistent advisory `launcher.lock`; the
   daemon's storage lock remains the authority for home ownership.
5. `Upgrade` requires the exact snapshot approved by the caller. It validates the
   replacement executable before stopping anything, rechecks the approved target,
   drains the supported daemon, and launches its replacement. If the target
   changed, the caller must obtain fresh approval. Unknown protocols cannot
   authorize shutdown.

`albedo daemon --stop` inspects the existing daemon without prompting or starting
one. An absent or stale daemon needs no shutdown. Discovery failures are reported.

## Authentication and defaults

Bearer authentication remains the same. The daemon owns its home directory and
token: by default it uses `~/.albedo` and generates a random token. It publishes
`daemon.json` atomically with mode `0600` inside the private home directory. The
record contains the endpoint, PID, protocol, token, and optional build identity:
an `ALBEDO_BUILD` label plus a content digest of the code tree the daemon runs
(sha256 over the sorted relative paths and bytes of every regular file under the
application's `ebin/` and `priv/` trees, symlinks followed; the CLI hashes its
candidate build with the same recipe, pinned across both implementations by the
fixture in `test/fixtures/build-digest`). It is a local discovery file, not an
API compatibility contract.

The shared `priv/bin/albedo-daemon` bootstrap installs VM defaults before Erlang
starts. Source, test snapshots, and packaged startup use that bootstrap. Deliberate
`ALBEDO_HOME`, `ALBEDO_TOKEN`, `ALBEDO_BUILD`, and `ERL_FLAGS` overrides remain
available; operator VM flags follow the defaults and take precedence. The local
launcher filters provider overrides so saved daemon configuration remains the
source of provider settings.

Cancellation ends discovery, lock acquisition, startup waits, shutdown waits,
and the restart prompt. It does not kill a detached daemon that has already
started. A client disconnect cannot stop a daemon shared by other clients.

## Client development

Use `Attach(ctx, snapshot, rediscovery)` for a validated API connection. Supply no
rediscovery callback when the endpoint is fixed. A local client can supply
`Rediscover`, which looks for a verified replacement without launching one.
API recovery uses the supplied callback and validates the new endpoint before
installing it. It does not know the client's home directory or executable.

Attachment requires protocol 3 and the `durable_inputs`, `session_replay`,
`collection_invalidation`, and `tool_progress` capabilities. Optional
features check their own capabilities. Authentication, malformed server responses, and
capability lookup failures propagate to callers.
