# Retry-safe operation admission

Session creation and user turn submissions use a client-generated UUIDv7 `operationId`. Covered submissions are text, images, continuation, and skill activation. Each intended action gets one ID, even when two actions have identical content. The client retains the ID and encoded request until it resolves the outcome. Failure to obtain random bytes prevents submission.

An accepted response means the daemon stored the action safely. It does not mean the assistant finished. Assistant generation, tool calls, and arbitrary command effects do not have an exactly-once guarantee.

## Ownership and atomicity

`daemon/operations.gleam` owns receipts and pending inputs in the core SQLite store. `daemon/conversation.gleam` commits session creation with its receipt and consumes pending input with its transcript changes. The store actor runs each transaction on its own connection.

The `operations` table survives session deletion. `pending_inputs` records acceptance order and the full resolved submission, including display text, model input, image, source, client echo metadata, and operation ID. Consumption writes transcript inputs and images, compact display metadata, receipt delivery state, and pending deletion in one transaction. A failure rolls back all of those changes.

Committed display metadata retains display text, source, client echo ID, operation ID, and optional original image MIME type, dimensions, and byte count. It contains no image content, image references, or resolved model text. The transcript and image store own those payloads. History displays the original upload dimensions even when the model receives a fitted image. An operations-owned commit descriptor carries this metadata and the transcript offset from submission preparation into consumption.

`continuation_markers` retains consumed continuations at their transcript boundary without adding a user-text row. These markers survive receipt expiry and go with the session on deletion. A creation receipt's target is the original session ID, including after deletion.

A failed admission transaction leaves neither an accepted receipt nor its mutation. A failed consumption transaction leaves the input pending and appends no transcript input. The session retains blocked work and retries preparation at most once every 15 seconds while it remains usable. Startup opens sessions with pending work, including sessions whose previous turn was idle.

## Requests and duplicate detection

`POST /sessions` requires `operationId` alongside the creation fields. `POST /sessions/:id/events` requires `operationId` alongside the submission fields. Text and images use `type: "user"`, which is also the omitted default. Continuation uses `type: "continue"`. Skill activation uses `type: "skill"`, `name`, and raw `arguments`, and resolves through the selected skill's preparation function. It does not execute an arbitrary command handler. The commands route refuses user skill activation; model skill calls still return instructions as data.

The fingerprint includes a version, operation kind, target session, and normalized request fields. JSON key ordering and omitted defaults do not distinguish actions. Image content and skill arguments do. Authentication and echo-only `clientId` do not. An explicit `submissionId` participates because it identifies ownership for targeted cancellation; otherwise ownership defaults to the operation ID. Provider defaults and skill content resolve on first execution.

An identical retry returns the original HTTP status and admission body. A changed request under the same ID returns `409 operation_conflict` and leaves the original decision intact. Receipt lookup precedes mutable workspace, provider, skill, and queue validation. Rejected decisions also replay their original status and error.

Sessions accept at most 32 waiting inputs, including while idle, blocked, interrupted, or opening a kernel. An identical retry uses no additional slot. A distinct request at capacity receives a durable rejection that still replays after the queue drains. Recovery restores every accepted pending input without truncation and refuses new admissions while the restored queue is at or above capacity.

## Query and retention

Authenticated `GET /operations/:operationId` returns the receipt, including its ID, fingerprint, kind, target, timestamp, admission status, original result or error, and HTTP status. A submission also reports `deliveryStatus`:

- `pending`: safely stored and waiting for transcript consumption. `blockingReason` can explain why delivery is waiting.
- `committed`: the input is recorded in the transcript. A continuation records its durable marker without adding a user-text row.
- `cancelled`: interruption or session deletion cancelled the waiting input.

Creation receipts have no delivery status. Interrupt cancels waiting accepted inputs and stops the active turn. Deletion cancels pending inputs before removing the session. A retry never resurrects cancelled input or recreates a deleted session.

The daemon keeps receipts for seven days after their terminal outcome. Pending inputs and their receipts never expire. Cleanup removes expired terminal receipts in batches of at most 128. Existing receipts are checked first. An unknown ID more than seven days old returns `410 operation_expired` and cannot execute. An ID more than five minutes ahead returns `400 operation_future`.

A missing young ID returns `404 operation_unknown`. This result does not prove that an earlier in-flight request cannot still commit. Recovery retains the same ID.

## Client recovery boundaries

The Go client retains an explicit operation handle with the original encoded request. After transport loss, an invalid acknowledgement, or a server error, it queries the receipt and permits one automatic replay of the same request within the existing deadline. Cancellation stops retries and preserves the handle. A later query resolves that action without another submission POST. The prompt CLI also requests cancellation of its own submission on timeout or cancellation: queued input is removed atomically with its cancelled receipt, while a shared running turn continues for its other participants.

Pending UI rows match durable events by operation ID. Identical text from different actions cannot settle each other's pending rows. The TUI retains pending submission handles when you switch sessions and queries them when you return. Uncertain creation also keeps its handle across navigation; recovery adds the original session to the picker without changing the selected session. General commands, settings, interruption, child creation, and external effects retain their separate uncertainty handling and do not use this automatic replay policy.

`410 operation_expired` ends automatic recovery. The client returns an uncertain outcome with the original handle and sends no further automatic receipt queries or submission requests for that action. Expired user rows keep their IDs and attachments and remain visibly unresolved, but do not count toward the pending-send limit. Expired continuations retain an unresolved note with their operation ID. These states survive navigation. A matching durable user event can still reconcile an unresolved row. Expired creation retains its handle and notice without changing the selected session.
