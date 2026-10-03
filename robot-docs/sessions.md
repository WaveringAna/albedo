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

Session streams require the `text/event-stream` content type. Each batch carries
a nonempty `generation`, a nonnegative integer `cursor`, and an `events` array.
The generation identifies one lifetime of the session actor. Reconnect requests
send both `after_generation` and `after_seq`; an initial request omits both.
A missing or different generation, or a sequence outside the replay window,
returns a durable transcript reset. Empty keepalive batches carry the current
pair too.

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
