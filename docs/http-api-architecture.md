# HTTP API architecture

[OpenAPI](openapi.yaml) defines wire shapes. [HTTP API design](http-api-design.md)
defines ordering, retry, recovery, and resource behavior. This document explains
the owners and persistence boundaries behind those operations.

## State ownership

Session actors, the store transaction connection, the family owner, the
settings lock, and the bounded bus own the state below. HTTP handlers call
these owners and project their results.

`session/creation` owns new, fork, and child intents, their canonical submitted
JSON, and rejection policy. `http_api` parses requests into that type. The
registry resolves defaults and coordinates creation; `conversation` and
`operations` persist the submitted intent and the resulting decision. Dependency
failures stay retryable; validation refusals retain their original fingerprint
and rejection.

The runtime owns a generic `store.Store` handle named `ledger`. Extensions such
as work initialise and consume their own tables through that handle. Kernel APIs
accept the same generic store and receive their plugin wiring from callers.

| State | Owner and commit boundary | Recovery and removal |
| --- | --- | --- |
| Creation intent and decision | `conversation` and `operations`, on the shared store transaction connection. Persist the submitted descriptor separately from resolved defaults and editable configuration. | Keep provenance while the session exists. Keep rejected decisions and deletion tombstones for the contract's seven-day window. A lost response is recovered by the same session URI and original ID. |
| Child creation and initial task | Family owner serializes membership validation. One store transaction commits session, relationship, creation decision, and identified task. | A failed commit leaves none of them. Deletion admission prevents a racing child from escaping captured membership. |
| Input admission | `operations` commits the immutable decision and pending input together. Check a known ID before mutable validation. | Accepted pending input survives restart. Queue-full rejection stays rejected on retry. Unknown expired IDs cannot execute. |
| Input consumption and turn outcome | Session actor orders execution. Store owner commits transcript rows, images, input delivery, turn membership, and pending removal together. | Failed consumption leaves input pending. An unfinished previous run becomes abandoned after restart. Start seven-day receipt retention only when both delivery and the associated turn are terminal. |
| Configuration and workspace intent | Session actor validates its configuration revision and idleness. Family owner captures descendant membership; store owner commits desired workspace and deferred descendant intentions. | Persist desired revision before kernel work. A late completion cannot restore an older workspace. Report failed application separately from committed desired state. |
| Visits and deletion | Store owner commits visit identity with the counter, and deletion outcomes with pending cancellations and tombstones. Family owner serializes captured subtree changes. | Repeated visits do not increment again. Partial deletion reports the actual captured remainder. Never automatically repeat subtree deletion after transport loss. |
| Session watch | Session actor captures live state, replay position, and durable high-water mark together. Generation belongs only to that actor lifetime. | Reset reads history through the captured high-water mark. Advance the client's cursor pair after delivery succeeds. Actor replacement cannot authorize old numeric replay. |
| Collection watch | Existing bus admits bounded notifications before subscriber mailboxes and coalesces wakes. | Overflow and closure require resubscription followed by authoritative refresh. Disconnect removes subscription state. No duplicate full-event mailbox queue. |
| Settings and credentials | Existing settings owner constructs the candidate under the per-home lock. MCP connection probes run outside the lock; publication rechecks the group validator and private candidate inputs. | Use the crash recovery procedure below. Runtime application is distinct from persistence. Secrets remain write-only. |
| Provider login | OAuth owner owns the bounded live listener/exchange. It owns durable admission and terminal records through the supplied store transaction connection. | Persist admission before opening a listener. Restart marks unfinished records failed. Preserve terminal decisions for 15 minutes; a duplicate ID cannot start another exchange. |
| Prepared context | Existing runtime owner publishes one immutable latest prepared snapshot. | Paging pins its ID; replacement returns `410 context_changed`. Reading context never prepares a request. |
| Extension ledgers | Each extension owns its tables, migrations, validation, permissions, and handlers. | Commit domain changes before best-effort notifications. Notification failure cannot undo committed work. |

Composition discovery runs outside the runtime actor in bounded preparation
workers. Admission reserves capacity for both observations and preparation, so
slow kernel starts cannot occupy every read slot.

### Settings crash recovery

Provider and MCP changes publish public settings and `creds.json` atomically.

The settings owner uses the per-home lock and a private recovery record for
a pending group replacement:

1. Recover any prior replacement before reading or changing settings. All
   credential writers, refreshes, and readers that can observe these files
   participate in this boundary.
2. Read the current group, check `If-Match`, and construct the complete candidate
   while retaining unrelated sections. Resolve conflicting secret sources and
   validate the candidate before changing authoritative files.
3. Write the complete replacement documents into private temporary files.
   Set mode `0600` before writing secrets. Sync the files.
4. Publish a private recovery record containing the complete replacement
   documents and their allowed destination names. Sync the record and its
   directory. Publication is the durable commit decision.
   Before this point, failure leaves the old group authoritative.
5. Replace the affected files and sync their directory. After the commit
   decision, recovery completes those replacements; it does not undo them.
   Recovery can regenerate a consumed temporary file from the record, so a
   crash after the first rename does not lose the remaining replacement data.
6. Remove the recovery record and temporary files only after replacement is
   durable. Then expose the new group and validator to readers.

Crash before the commit decision keeps the old group. Crash after it completes
the new group on restart. An inability to finish recovery fails startup or the
settings operation with an actionable storage error; it cannot expose a mixed
snapshot. Keep old runtime composition usable until candidate application
succeeds. A post-commit application failure reports the persisted desired state
and failed application, without claiming persistence rolled back.

Scope this mechanism to the existing settings owner. Do not create a generic
file transaction library. Bound each replacement by its existing file limit
and the recovery record by the sum of those limits plus bounded metadata.
Reject a recovery record with foreign paths, invalid contents, missing
replacement data, or unsafe permissions. Never log its secret
contents. Exercise real crash points before and after the commit decision.

### Durable facts

Creation provenance, turn-terminal retention, workspace intent, and login
admission are durable. Their owners migrate their records before actors start.
Migration failures stop startup before admitting work.

For a session created before provenance was stored, expose unavailable
provenance explicitly. Do not infer its original request from its current name,
workspace, or model. Existing history, forks, and attachments remain usable.
Such a session returns `creation: null` in the single target schema and cannot
prove a matching identified creation.

Login intent comparison includes private form values. Use a keyed fingerprint
with a protected, persistent daemon-owned key rather than a publicly readable
hash of a low-entropy password. Do not persist callback codes or access tokens
in admission records. The OAuth owner removes fingerprint metadata when the
record expires; the credentials owner continues to own resulting accounts.
