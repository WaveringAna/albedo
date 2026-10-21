# Shared runtime helpers

## clocks

`albedo/clock.gleam` owns Gleam clock access. Use `system_ms` or
`system_seconds` for durable timestamps and expiry, `monotonic_ms` for elapsed
time and deadlines, and `os_system_ms` only when OS-clock semantics are required.
Store slow-query timing uses `clock.monotonic_ms`. Reuse these functions instead
of adding local clock externals or wrappers. Erlang native time units are
VM-dependent; request an explicit unit rather than dividing native ticks.

## Unicode scalar limits

`albedo/text_scalars.gleam` owns scalar counting and slicing. Its `length`,
`take`, `drop`, and `tail` scan UTF-8 without creating a whole codepoint list;
retained slices are copied so they release the source binary. Scalars are not
graphemes. Use these helpers for bounded previews and names, including from
Erlang through `'albedo@text_scalars':take(Text, Limit)`. The kernel job summary
retains at most 4096 scalars; truncating it must not allocate a list for the
entire command.
HTTP response previews and operation validation also use `text_scalars.take`;
their scalar-prefix adapters do not maintain a separate native implementation.

## shared values

`albedo/shared.gleam` owns values every process reads without copying.
`publish` stores one in a persistent term and answers a `Shared(a)` handle;
`read` returns the literal, which a spawn or send does not copy (a sublist of
it copies cons cells only). Publishing and `release` each scan every process:
publish once per lifetime, release in the owner's `stop`. Reading a released
handle panics. `runtime.Runtime` holds its installed extensions this way, so
a runtime copied into an HTTP request or a turn's worker costs a few words;
`test/harness/runtime_test.gleam` fails when the handle or a selection over
the installed list carries a copy. A literal references module code, so the
daemon does not hot-load a module while a shared value from it exists.

A daemon-wide fact found once at boot, with no owner to hand a handle to, is
a persistent term under a module's own key instead: `albedo/daemon/webhook_intake`
holds the bound intake port (`publish` at boot, `clear` when the intake stops,
`port` for readers). An integer copies nothing, and the one erase happens only
when the intake gives up.

## listeners

`albedo/daemon/listener.keep` runs a listener under a keeper and reports its
first start within a wait. A start that outlasts the wait returns `TimedOut`
after the keeper is killed, so it never comes up behind the caller. Later
exits restart it after a doubling pause: `Always` for the daemon's own port,
`Bounded(attempts, stopped)` for the webhook intake, which stops and runs
`stopped` after that many failed starts in a row.

## code loading

Erlang loads a module on its first call, and a package upgrade (Homebrew's
cleanup, say) can delete the install a daemon is still running from; the
first call into an unloaded OTP module then fails with `undef`. Right after
readiness, `albedo_code:start/0` loads, in the background, every module of every
application reachable from `albedo`: declared dependencies plus the owners of
every module their code imports (inets is reached this way; build tools on the
code path such as Elixir and Mix are not). The outcome is kept in the
persistent term `{albedo_code, preloaded}`. A runtime call that names a module
only dynamically, in an application nothing imports, is not covered: import
it, or declare its application. ERTS port programs and OTP priv files cannot
be preloaded, so `GET /server` adds a `runtime-removed-<instance>` warning
notice once the install's `lib` directory is gone.

## native boundaries

Keep process state, ports, monitors, ETF, and native binary matching in their
Erlang owners. Reuse Gleam owners for pure validation and text projection.
A new Erlang shim should supply a native capability, not duplicate an existing
Gleam helper. Keep typed values through internal projections and encode JSON at
the wire boundary; see [command state projections](commands.md#contributing-commands).

`daemon/active_output.gleam` owns unfinished response identities, limits, and
projection transitions. Its native helper owns buffered spill file I/O, range
reads, leases, and filesystem cleanup. Capture flushes by absolute offset so
capturing the same immutable projection cannot append its buffered tail twice.
Do not move projection policy into an opaque Erlang map or reconstruct output
from replay events. The [session attachment contract](sessions.md) defines
cursor consistency, commit replacement, and reference lifetimes.

## session diagnostics

`daemon/session_diagnostics.gleam` owns named facts from `session_state.State`
for native probes: watcher owners, sequence, history residency, tool progress,
and the current run's worker. Erlang probes must call these typed accessors
instead of indexing the state tuple or searching its fields by constructor tag.
The memory inspector reports numbered fields and sizes; it must not mirror
Gleam record names or create atoms for field labels.

## storage concurrency

`daemon/store.gleam` owns one ordered writer connection and four read-only connections for a file-backed database. `query` and `write` run on the writer. `read` uses SQLite's statement snapshot without opening an explicit transaction; `snapshot` runs a read-only callback in one deferred transaction on a reader. `store/readers.gleam` admits reads to idle connections on a separate actor, so a queued writer or one slow reader does not delay reads when another connection is free. Waiting reads use a FIFO queue. SQLite WAL permits readers and the writer to run together. Writes still serialize, and a session actor waiting for its own durable write cannot handle another message until that write returns.

A snapshot sees committed data from its first read. All related reads, including image payload lookups, use the supplied connection. Snapshot callbacks must not call Store-level APIs, retain their connection, or write. Read-modify-write operations and mutations with `RETURNING` use `query` and stay on the writer. A read after an acknowledged write sees that commit; a read concurrent with an uncommitted write can see the previous committed state.

Reader connections use private SQLite caches with a 128 KiB suggested page-cache limit each (512 KiB across four readers), rather than four default-sized caches. Schema and connection allocations are additional; this is not a total memory cap. Reader connections belong to the store lifetime and close before the writer. A failed connection owner fails the store rather than leaving a live handle with reduced capacity. Private in-memory databases retain one connection and serialize snapshots with writes. Their snapshots still enforce read-only access.

## finite actor calls

`albedo/actor_call.gleam` owns monitored calls that return `TimedOut` or
`CalleeDown` and remove their monitor on every outcome. Reuse `try_call` for
finite waits instead of copying subject lookup, reply selection, and monitor
cleanup. Callers own deadlines and translate failures into their domain errors;
a timeout does not cancel accepted work.

Kernel upgrade completion keeps its repeated wait until completion or owner
death. Session closure also waits for owner termination after the acknowledgment.
These lifetime protocols need more than a finite request/reply call.

## registry host lookup

`daemon/registry.host` owns the five-second runtime-host lookup. Callers retain
`Result(Runtime, String)` and map failures at the HTTP boundary. Reuse this
function rather than sending `Host` with a local copy of its timeout. Page
contributors construct `page.Row` directly; forwarding constructors add no policy.

## closure registry tables

`daemon/albedo_registry.erl` creates closure-registry ETS tables lazily. A
registering caller monitors the creator and waits for a tagged readiness
acknowledgment or explicit startup failure before inserting. The winning owner
outlives the callers; concurrent losing creators acknowledge the existing
table and exit. Keep this lifetime independent of daemon boot so embedded
runtimes work too. Never replace readiness with a sleep or bounded polling.

## HTTP route inventory

`test/harness/http_routes_test.py` compares daemon and extension dispatch arms with `docs/openapi.yaml` operations without booting a daemon. It normalizes parameter names and checks method/path pairs in both directions. It reads outer dispatch arms in the current Gleam layout and the OpenAPI path/operation indentation; new routing syntax needs an extractor update. The Go E2E contract transport checks response schemas for requests it exercises, and `test.sh` separately checks generated Go bindings with `apigen -check`.
