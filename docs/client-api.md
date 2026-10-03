# Client API ownership

The Go `daemon` package owns the daemon protocol. Application commands and TUI
screens call named operations and receive typed results. They do not construct
daemon routes, select HTTP retry policies, or decode response envelopes.

## Request flow

Previously, some screens assembled session URLs, built JSON maps, checked
capabilities, and decoded responses themselves. Other screens already used
named operations. A malformed response could become an empty successful result.

Opening a context page now follows one flow:

1. The screen calls `GetContextPage` with its session, section, and page.
2. The adapter checks the required capability, constructs the request, and
   enforces its deadline and response bounds.
3. The adapter checks the response and returns a typed page or an error.
4. A typed UI message carries the result back to the screen. The screen owns
   selection, rendering, and rejection of outdated replies.

Session lists, previews, agents, trees, models, commands, catalogs, pages, and
webhooks use the same ownership boundary. Extension-specific command results
remain explicit `json.RawMessage` values. Tool arguments and tool results used
for local display can also remain dynamic data.

## Code organization

Each domain keeps its requests, results, operations, and decoders together.
Sessions, submissions, models, agents, context, trees, settings, catalogs,
pages, and webhooks have their own files. Session stream parsing is separate
from the other chat operations. Transport execution, shared JSON decoding,
and receipt recovery remain private adapter machinery.

The CLI owns plain session-list rendering. The presentation package owns
shared session text sanitization and age formatting. Local discovery and
launcher operations keep their separate files and responsibilities.

## Changes and recovery

Typed requests preserve omitted values, explicit removals, and false values.
Leaving a preference unspecified keeps it. Disabling it sends false. MCP secret
patches distinguish keeping a secret, replacing it, and removing it, including
individual header and environment names.

Reads can recover through the connection's existing rediscovery callback.
Ordinary mutations can retry an explicit authentication refusal only when it
means the daemon did not admit the action. A lost acknowledgement does not
authorize replay. Creation and submission keep their original operation IDs
and encoded requests while resolving receipts. An operation handle exposes
its immutable identity through `ID()`; callers cannot replace that identity.
Shutdown does not recover.
A page-loading command follows command recovery rules even though the screen
uses it to display information.

Confirmed changes remain visible when a later step fails. For example, a
successful model selection survives a failed cap update, and a newly generated
webhook secret remains available after a later configuration step fails.

The model picker calls `ChangeModel` and `SetModelContextCap`; the adapter
owns command encoding and capability checks. Catalog, capability, and MCP
updates use named request structs instead of adjacent positional strings.
Webhook mutations return the updated hook as well as preserving any generated
secret from creation or rotation.

## Local startup stays separate

Discovery, attachment, launch, and upgrade retain their existing responsibilities.
The interactive CLI still offers to restart a running daemon once per invocation.
Keeping it running is the default, and replacement requires the user's choice.
API recovery cannot launch or replace a daemon.

[Daemon attachment and local startup](daemon-lifecycle.md) describes the startup
policy, authentication, and operator overrides.

## Live tool progress

Session and agents stream subscriptions require the `normalized_tool_progress`
capability. The daemon owns argument decoding and bounded progress. Clients
validate and render the updates.

`tool_progress` carries a `progress` object with `callId`, `name`, and `phase`.
The phase is `generating` or `running`. Optional fields are
`toolCallId` and `code` with `offset` and `text`. Null progress clears live
progress for the session.

The daemon coalesces preview updates over 100 ms and publishes first appearance
and running transitions immediately. Attachment snapshots include the latest
preview, including updates awaiting publication.

`callId` identifies progress across generation and execution, with a new identity
for each actor lifetime, run, provider step, attempt, and output index.
`toolCallId` is the native tool-call identity when available. A completed `tool`
event keeps its native `callId` and adds `progressCallId` to end the matching
progress.
Durable history retains the original tool arguments and results.

Each code update replaces the preview with the latest 512 Unicode scalar values,
up to 2,048 UTF-8 bytes. `offset` counts decoded source scalars before the window.
JSON escapes, bytes, grapheme clusters, and terminal columns are not offset units.
Progress events have an 8 KiB limit. Names have a 100 UTF-8 byte limit and end at
valid UTF-8 boundaries. Native IDs over 200 bytes are omitted, never truncated.

Reset batches include `currentProgress`, captured with the generation and cursor.
Clients apply history first, then the snapshot as live progress. They save the
cursor pair after every callback succeeds. An empty array means no live tool
progress. Incremental batches omit `currentProgress`.

The daemon tracks at most 32 generating calls per provider attempt. Excess calls
clear and disable generating previews for that attempt. Complex arguments can
omit the preview while execution continues. Retry, cancellation, failure, and
completion clear obsolete progress.

## Storage reports and offline diagnosis

`albedo storage` attaches to an existing daemon and calls `GetStorageReport`.
The authenticated `GET /storage/report` route requires the `storage_report`
capability. The daemon inspects its own database and files; online clients need
neither Python nor access to that installation's storage files.

When discovery proves the daemon absent or its record stale, reporting uses
read-only local inspection automatically. Authentication, protocol, health, and
transport failures remain errors. `albedo storage --offline` explicitly selects
local diagnosis, including when a daemon is running or unreachable. Reporting
never launches or restarts a daemon.

Offline inspection requires Python only when a database exists. It recognizes
layouts from before pinned context and cell traces, optional image and cell
tables, and earlier TEXT image storage without migrating them. Layout recognition
uses the columns needed for accounting, rather than a new schema version marker.
Missing storage produces an empty database report without creating files;
unsupported required columns produce an error rather than an incomplete
successful report.

The offline inspector reads a temporary copy of the database and any WAL.
SQLite may create a private SHM file there, leaving the installation untouched.
If storage changes during copying, diagnosis fails and asks you to retry when
the daemon is quiet. The temporary copy needs space for the database and WAL.

Session sizes estimate selected stored content: pinned context, transcripts,
cell source and payloads, and cell traces. Shared images are counted separately,
once each. These estimates retain SQLite's existing length arithmetic and do
not describe allocated disk space per session. Database size measures the main
file; the `wal` field includes both WAL and SHM. Database measurements are
collected together, while file sizes reflect the filesystem during inspection.

Old orphan state files and recognized migration backups become cleanup
candidates after 30 days. A report does not authorize deleting them. Local
cleanup takes the existing exclusive ownership lock and rechecks locally
approved candidates before mutation. Paths returned by the daemon never
authorize local deletion. Session deletion uses the daemon's report and API.

## Adding a client operation

Add the named operation and its request and response types to the adapter first.
Put route encoding, required capabilities, accepted statuses, response checks,
limits, and recovery rules there. Call it from the application or screen and
translate its result into UI state through a typed message.

Use the real-daemon harness to test observable workflows. Controlled HTTP tests
cover malformed responses and failures that a healthy daemon cannot produce.
Keep generic transport helpers private and reuse existing decoding where it
expresses the current contract. Do not add a wrapper that merely forwards an
unrestricted request.
