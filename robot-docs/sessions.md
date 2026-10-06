# session attachment

Session creation and user turn admission use durable [operation receipts](operations.md).
An accepted submission survives a daemon restart while it waits for transcript
consumption. A retry with the same operation ID returns the original admission.

opening a session attaches the cli to its event stream and independently
reads `GET /sessions/{session_id}?tail=0`. replayed history does not establish the
session's live phase; status and live events do.

an idle status is enough to enable the composer, including a persisted
`interrupted` session after a daemon restart. a missing or unrecognized
phase is display metadata, not a failed connection. before live status is
known, enter preserves the draft; superseded status replies cannot unblock
it. starting a new turn does not require `/compact` to change the old phase.

## Stream failures and recovery

Internal checkpoint and provider-started signals are suppressed before stream
encoding and do not allocate SSE sequence numbers.

Session streams require the `text/event-stream` content type, zstd-coded when
the request accepts it ([encoding](../docs/http-api-design.md)): `http_stream`
flushes the coder after every frame and ends the frame before a deliberate
stop. A zstd context works only in the process that created it, so the stream
process creates its own writer. Each batch carries
a nonempty `generation`, a nonnegative integer `cursor`, and an `events` array.
The generation identifies one lifetime of the session actor. Reconnect requests
send both `after_generation` and `after_seq`; an initial request omits both.
A missing or different generation, or a sequence outside the replay window,
returns a durable transcript reset. Empty keepalive batches carry the current
pair too.

Attachment requires `session_replay` capability version 2. Reset snapshots
include `active_output`: unfinished text and thinking captured with the same
actor cursor as the durable history watermark. The session actor owns this
projection. Do not reconstruct it from the replay ring or bounded activity
previews, which may have already discarded the beginning of a response.

The projection retains at most 64 KiB of raw inline text and emits at most
64 KiB of encoded inline content across its segments. Larger output spills to
temporary files with 16 KiB buffered writes. Capture flushes pending writes
before returning references. Each reference fixes the byte cutoff at capture;
later deltas cannot extend that prefix. Full-content pages use
`/sessions/{session_id}/active-output/{content_id}` and retain the original
`snapshot` query while following `next` tokens.

The CLI stages complete prefix hydration before replacing its transcript,
then restores history and active output before processing later events.
Provisional chunks retain message identity even after the live display buffer
settles them. Canonical assistant and thinking publication precedes
`committed.replaces_live_ids`, which identifies matching provisional chunks.
Model commits set `replaces_all_live` to retire all provisional output, including
fragments absent from the bounded projection after a storage failure.
Retry identities never reuse a failed attempt's content. Cancellation and
failure retire remaining provisional output without changing durable history.

Issued spill references live for 15 minutes across commit and retry. Existing
maintenance removes expired and orphaned files; session deletion revokes them.
Spill storage is bounded to 64 MiB per run, 1 GiB across retained files, and
4096 retained files. A projection has at most 256 segments. Spill directories
use mode `0700`; content and metadata use `0600`. Owner identity includes the
VM incarnation so reused PIDs cannot retain orphaned files after restart.
Storage failure makes backfill explicitly unavailable rather than returning a
truncated successful snapshot. It must not abort generation or discard a
durable commit. Expired references return `410 active_output_expired` and cause
the client to capture a new snapshot. Do not add compatibility readers for
snapshots without active output.

Session subscribers receive coalesced wake notifications. Event payloads stay
in the session's existing replay buffer; a successful frame acknowledges its
cursor before another wake is issued. A subscriber's death removes its watch
without requiring another event.

The CLI validates the whole batch before consuming it and saves both cursor
values only after every callback succeeds. Initial attachment and a generation
change require a leading reset. Within one generation, the sequence cannot
decrease without a reset. A generation change with a reset is normal recovery.
A change without a reset is a protocol failure. The reset replaces visible
history and clears live tool progress. Reset batches include `current_progress` in the captured session snapshot. The CLI delivers that snapshot after history as
live progress, so attaching during a tool call restores its current tool name,
phase, and bounded code preview. Older-history navigation uses transcript row IDs.
Unknown event kinds are ignored.
Missing kinds and malformed known events are protocol failures.

Transport failures, ordinary EOF, HTTP 408/429, and server errors reconnect with
a delay starting at 500 milliseconds and increasing to at most five seconds.
EOF and transient failures retain the saved pair. Cancellation ends the
subscription quietly and clears the pair, as does explicit protocol recovery.
Other HTTP refusals, explicit SSE failures, and consumer callback failures end
the subscription with a visible notice. A terminal failure also stops status
polling for that attachment.

The TUI attempts one durable transcript reset per attachment after a protocol
failure. It clears live tool progress and requires the recovery stream to
begin with a reset. A second protocol failure ends automatic recovery; reopening
the session starts a new attachment. Pending submissions and drafts remain
available, and a stream failure does not claim that model execution finished.

## Loaded sessions and unloading

A session is loaded while its actor runs; only a loaded session has a stream
cursor. Opening it, watching its stream, or submitting to it loads it. Reading
`GET /sessions/{session_id}/history` never does, so the session list previews
stored history instead of the session resource.

The maintenance sweep releases an idle kernel after `ALBEDO_IDLE_SECONDS`
(default 10 minutes) and unloads a session whose last turn (`activity_at`) is
older than `ALBEDO_UNLOAD_SECONDS` (default one hour): the provider's prompt
cache has expired by then. The session refuses while a turn runs or waits, a
client watches its stream, a background job is live, or one of its children
works — runs a turn, or sits between turns on a job of its own, or has a child
that works: that child's report will wake it, and its prompt cache may be kept
warm meanwhile (robot-docs/cache-warming.md). Unloading saves the kernel's
variables like a release. The next request loads it again.

Listing sessions reads loaded sessions' summaries but does not count as
attention, so an open session list never keeps a kernel alive.

The same sweep collects every waiting process whose heap passed 1 MB
(`albedo_daemon:collect_idle`): a long-lived actor otherwise keeps the heap a
busy turn grew it to. The launcher's VM defaults (`priv/bin/albedo-daemon`)
then hand the freed carriers back to the OS instead of caching them.

The session list marks a session active (green) while it is loaded and its
last turn is under an hour old.

## asynchronous persistence failures

The dispatcher logs failures to advance delivered schedule occurrences or save mail delivery errors. Undelivered mail and unadvanced schedules remain durable and retry under the existing dispatch policy. A schedule whose submission succeeded but whose advance failed can be delivered again.

## Prompt ownership and cancellation

Inputs use `PUT /sessions/{session_id}/inputs/{input_id}` with a client-generated
UUIDv7. The same identity follows admission, transcript consumption, turn
membership, and cancellation. Accepted inputs survive restart. The
[input contract](../docs/http-api-design.md#input-admission-and-outcomes)
defines message, continuation, skill, and command variants.

`POST /sessions/{session_id}/inputs/{input_id}/cancel` returns the current input
and `cancelled`, `interrupt_requested`, `shared_running`, or `not_pending`.
A waiting cancellation commits its receipt and pending removal together. A
running turn shared with other inputs continues. Cancellation never falls back
to a session-wide interruption or affects a later unrelated turn.

The CLI uses a separate five-second cleanup deadline and reports unconfirmed
cancellation when cleanup fails. An interruption acknowledgement does not claim
that work stopped.

Live turn membership precedes worker output and expands when queued input
steers a turn. Completion follows its final output or failure. The durable input
read retains membership and terminal outcome across reconnects and restarts.
Prompt clients follow their input identity instead of inferring completion from
echo metadata or idle status. Drafts and unresolved input handles survive resets.
