# session attachment

Session creation and user turn admission use durable [operation receipts](operations.md).
An accepted submission survives a daemon restart while it waits for transcript
consumption. A retry with the same operation ID returns the original admission.

opening a session attaches the cli to its event stream and independently
reads `GET /sessions/:id/status`. replayed history does not establish the
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
history and clears partial tool arguments. Older-history navigation continues
to use transcript row IDs. Unknown event kinds are ignored.
Missing kinds and malformed known events are protocol failures.

Transport failures, ordinary EOF, HTTP 408/429, and server errors reconnect with
a delay starting at 500 milliseconds and increasing to at most five seconds.
EOF and transient failures retain the saved pair. Cancellation ends the
subscription quietly and clears the pair, as does explicit protocol recovery.
Other HTTP refusals, explicit SSE failures, and consumer callback failures end
the subscription with a visible notice. A terminal failure also stops status
polling for that attachment.

The TUI attempts one durable transcript reset per attachment after a protocol
failure. It clears partial tool arguments and requires the recovery stream to
begin with a reset. A second protocol failure ends automatic recovery; reopening
the session starts a new attachment. Pending submissions and drafts remain
available, and a stream failure does not claim that model execution finished.

## asynchronous persistence failures

The dispatcher logs failures to advance delivered schedule occurrences or save mail delivery errors. Undelivered mail and unadvanced schedules remain durable and retry under the existing dispatch policy. A schedule whose submission succeeded but whose advance failed can be delivered again.

## Prompt ownership and cancellation

`POST /sessions/:id/events` accepts an optional `submissionId` alongside
`clientId`. The CLI generates a new submission ID for each prompt. The session
actor owns queued submissions and every input contributing to an active turn,
including inputs without an ID.

`POST /sessions/:id/cancel-submission` takes `{ "submissionId": "..." }`.
The actor returns `outcome` atomically:

- `cancelled_queued`: removed that submission from the queue.
- `interrupt_requested`: requested interruption of its exclusively owned turn.
- `shared_running`: other inputs contribute to the turn, which continues.
- `not_pending`: the submission is neither queued nor active.

Cancellation never falls back to session-wide interruption. Repeating the
request is safe. An interruption acknowledgment does not confirm that work
stopped. The CLI uses a separate five-second cleanup deadline and reports an
unconfirmed cancellation when cleanup fails.

Ordered live `turn_membership` events carry `turnId` and `submissionIds`.
Membership precedes worker output and expands when queued input steers a turn.
`turn_completed` carries the same `turnId` after its final output or failure.
Retries and compaction within the turn preserve this identity. These events
are live bookkeeping, not durable transcript rows. Prompt clients follow their
submission through completion instead of inferring ownership from `clientId`
or session idle status. A stream reset before completion leaves the outcome
uncertain. Daemon health advertises `submission_cancellation`; CLI prompts
require that capability before submitting.
