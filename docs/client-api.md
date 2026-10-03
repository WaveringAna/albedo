# Client API ownership

The Go `daemon` package owns protocol 3. Application commands and TUI screens
call named operations and receive typed results. The adapter constructs routes,
encodes requests, checks responses, bounds decoding, and chooses recovery policy.
[OpenAPI](openapi.yaml) defines the wire format;
[HTTP API design](http-api-design.md) defines its behavior.

## Request flow

Opening a context page follows this flow:

1. The screen calls `GetContextSnapshot` to obtain the latest prepared snapshot.
2. It calls `GetContextPage` with that snapshot ID, section, and page.
3. The adapter validates the response and returns a typed page or an error.
4. A typed UI message carries the result to the screen, which owns selection,
   rendering, and rejection of outdated replies.

Reading context does not prepare a model request. If the snapshot changes,
the client obtains the new summary before requesting its pages.

## Code organization

Each domain keeps its operations and application-facing types together.
Wire types live in `wire.go`; conversion stays inside the adapter.
Session stream parsing is separate from chat operations. Transport, decoding,
and receipt recovery are private machinery. Extension-specific result bodies
remain explicit `json.RawMessage` values.

Local discovery and launching have separate responsibilities. API recovery
cannot launch or replace a daemon. The interactive CLI still offers to keep or
restart a running daemon; replacement requires the user's choice.
[Daemon lifecycle](daemon-lifecycle.md) describes startup and operator overrides.

## Changes and recovery

Typed patches preserve omitted fields, explicit removals, and false values.
Configuration writes use the observed resource validator. A stale screen cannot
silently overwrite a newer edit.

Reads can recover through rediscovery within the caller's deadline. Identified
creation and input recovery retain the original ID and encoded intent. Other
mutations do not automatically replay after a lost acknowledgement. Canceling a
request does not cancel accepted input, interrupt a turn, or stop a shared daemon.

Session SSE uses an actor generation and sequence. The client saves both only
after delivery succeeds. A reset replaces visible history and live progress;
older durable history remains available through paging. Collection SSE carries
invalidations. Initial reset and overflow require authoritative refresh.

The daemon owns bounded tool progress and argument parsing. Clients validate
and render the normalized updates. Preview offsets count decoded Unicode scalar
values. Full arguments, results, and recorded traces remain in durable history.

## Storage reports

`albedo storage` reads the authenticated `/storage` resource through
`GetStorageReport`. The adapter traverses report pages; the daemon inspects its
own files and database. Online clients need neither Python nor filesystem access.

Proven absence or a stale discovery record selects read-only local diagnosis.
Authentication, protocol, health, and transport failures remain errors.
`--offline` deliberately selects local diagnosis, which inspects a temporary
database and WAL copy without changing the installation. Unsupported required
schema columns fail rather than producing incomplete totals. Cleanup requires
the local ownership lock and rechecks approved candidates before deleting files.

## Adding an operation

Add the named operation and typed result to the adapter. Keep route encoding,
accepted statuses, capability requirements, bounds, and recovery rules there.
Translate its result into application or UI state through a typed message.

Use real-daemon tests for observable workflows. Controlled transport tests cover
malformed responses and uncertain outcomes a healthy daemon cannot reliably
produce. Do not add public generic request helpers or forwarding wrappers.
