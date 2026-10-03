# Durable operation admission

Session creation and input admission use client-generated UUIDv7 identities.
Each intended action keeps one ID and its encoded request until its outcome is
resolved. Acceptance means durable storage, not assistant completion or
exactly-once external tool effects.

The [HTTP contract](../docs/http-api-design.md#creation-forks-and-children) defines creation;
[input admission](../docs/http-api-design.md#input-admission-and-outcomes)
defines input variants, duplicate detection, recovery, and retention.
[OpenAPI](../docs/openapi.yaml) defines request and response fields.

## Ownership and atomicity

`daemon/operations.gleam` owns receipts and pending inputs in the core store.
`daemon/conversation.gleam` commits creation with its decision, and consumes
pending input with transcript rows, images, display metadata, turn membership,
and pending removal. Transactions run on the store owner's connection.
A failed admission leaves neither its mutation nor an accepted receipt. A
failed consumption leaves the input pending and writes no transcript input.

Display metadata retains text, source, echo identity, input identity, and
original image dimensions without duplicating image content. Transcript and
image storage own payloads. Continuation markers retain consumed continuations
at their transcript boundary without adding user-text rows. Forks preserve
copied display facts, continuation markers, and recorded traces independently
of the original session.

Child creation commits family membership, creation provenance, its initial task
letter, and identified pending input together. That task has one delivery owner:
the identified input queue. Ordinary letters remain owned by the mail dispatcher.
Cancellation cannot make the dispatcher resurrect the initial task.

## Recovery

Creation recovery reads the chosen session URI. Input recovery reads the same
input URI, including after session deletion. Duplicate checks precede mutable
workspace, provider, catalog, and queue validation. Changed intent conflicts;
echo-only metadata does not change intent. Accepted pending input and unfinished
turn receipts do not expire. Terminal decisions and deletion tombstones remain
for the contract's recovery window.

The Go adapter retains an operation handle with its immutable identity and
encoded request. Recovery stays within the caller's deadline and uses the same
identity. Canceling a client request stops waiting, rather than undoing accepted
work. Targeted input cancellation is a separate operation. Uncertain UI rows
remain until a matching receipt or durable event resolves them.
