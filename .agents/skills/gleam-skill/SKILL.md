---
name: gleam-design
description: Design, implement, refactor, and review idiomatic Gleam code using source-backed patterns for modules, custom and opaque types, explicit dependencies, state ownership, and concurrency. Use for .gleam projects, Gleam architecture reviews, OTP actors and supervision, ETS or Cell sharing, database handles, Lustre state, event-driven services, or deciding between message passing and ordinary state/value passing. Distinguish Erlang and JavaScript targets and avoid unnecessary actors, unsafe sharing, and generic abstraction sprawl.
---

# Gleam Design

Prefer ordinary values and functions. Introduce processes for a real concurrency,
ordering, resource-lifetime, or failure boundary. Introduce shared mutable storage
for a demonstrated access pattern with an explicit consistency contract.
Do not treat "Gleam runs on the BEAM" as a reason to actorify every module.

## 1. Inspect before designing

Load only the supporting references relevant to the task, not the entire corpus.

Read the project's `gleam.toml`, `manifest.toml`, entrypoint, relevant modules,
FFI, and tests. Establish the compiler/library versions, supported targets, and
existing public contracts. Follow coherent local conventions rather than imposing
a new architecture because a reference repository uses it.

Trace one representative path end to end: input decoding, domain operation,
state access, effects, response, and recovery. Read the actual dependency API
before using version-sensitive OTP, selector, database, or framework functions.
Consult source/documentation when local dependency code does not answer a
material question. Do not guess APIs from old examples.

For a small pure helper, implement and test the helper; do not produce an
application architecture document. For stateful changes, identify:

- The authoritative state and any derived snapshots or caches.
- The owner, readers, writers, and lifetime of each state/resource.
- The invariant, atomic operation, readiness condition, and failure behavior.

Use a compact ownership ledger when several resources interact:

```text
resource | authority/owner | readers/writers | consistency | restart/close
```

## 2. Choose the smallest mechanism

| Need | Default choice | Check before escalating |
| --- | --- | --- |
| Local transformation or immutable config | Function arguments and returned values | Is any independent lifecycle needed? |
| Evolving data used by one execution flow | A record/Dict threaded through functions | Is there actually a second writer? |
| A safely shareable dependency | Explicit handle or captured context | Does this particular handle permit concurrent use? |
| Ordered decisions or asynchronous lifecycle | One actor owning the relevant state | What invariant or resource does it own? |
| Many readers of an occasionally replaced value | Published snapshot, possibly ETS-backed | Publication atomicity, writer discipline, readiness, lifetime |
| Concurrent independent updates | Documented atomic store operation | Does the guarantee cover the whole operation? |
| Durable or multi-record invariants | Suitable database transaction/authority | Which connection and isolation boundary apply? |
| Very rarely changed VM-wide data | Consider `persistent_term` only deliberately | Are its replacement and GC costs acceptable? |

Distinguish **sharing a value**, **sharing a resource handle**, and **sharing
mutable storage**. A record containing a cell or socket does not make the
referenced resource immutable. A typed handle does not prove liveness,
thread-safety, uniqueness, or correct lifetime.

For a tree or graph owned by one process, start with ordinary recursive values
or `Dict(Id, Node)`. Do not create an actor or a cell for every node or field.
Local value passing is not the same cost model as sending the whole structure
between processes.

Read [state and concurrency](references/state-and-concurrency.md) before adding
shared access, changing ownership, or relying on restart behavior.

## 3. Put types at the right boundaries

Use variants for meaningful alternatives, with the data needed by each variant.
Prefer `Idle | Running(run_id) | Stopping(run_id)` to correlated booleans and
optional fields. Keep independent dimensions independent; do not build a giant
sum type merely to avoid every optional field.

Use public records when callers should assemble data. Use opaque types when a
constructor must enforce an invariant, callers must not depend on representation,
or a handle should expose only selected operations. State the invariant rather
than adding wrappers by habit. A type alias is not a distinct nominal type.

Preserve relationships through type parameters: request/body, query/decoded row,
runtime/message, or snapshot/status. Use phantom states only when they eliminate
real invalid combinations; they do not enforce resource ownership by themselves.

Decode JSON, database rows, and foreign-runtime values at explicit boundaries.
Keep `Dynamic`, unsafe casts, and wire-specific shapes out of ordinary domain
logic. Preserve one canonical native model; do not invent JSON mirrors just to
move typed data between modules or local processes.

Keep expected failures in `Result` with useful error variants. Reserve assertions
for programmer invariants or intentionally fatal startup conditions. Distinguish
bad input, dependency failure, transport failure, and corrupted internal state.

Read [types and modules](references/types-and-modules.md) for examples from HTTP,
Pog, Squirrel, Birdie, and the standard library.

## 4. Separate module boundaries from process boundaries

Keep related types and operations in the module that owns their meaning. Extract
an `internal` module, adapter, or protocol module when there is a real boundary.
Avoid a catch-all `types.gleam`, duplicate model definitions, and one-module-per-
function fragmentation. Do not impose arbitrary file-size limits.

Compose dependencies at startup or the request boundary. Capture an immutable
context in a handler closure when appropriate; give lower-level functions the
narrow values or handles they actually need. Do not add a dependency-container
actor just to avoid passing a record.

For a complex event-driven service, consider separating a pure transition from
its executor. Keep business transitions, protocol decoding, worker supervision,
and persistence distinguishable. Do not require an effect framework for a simple
handler that can directly call a few functions.

Use pipelines for transformations, `case` for meaningful alternatives, and
`use` when callback composition improves readability. Inspect the called
function: `use` is callback syntax, not automatic async execution or `finally`.
A function-valued field can still do IO.

## 5. Design the process protocol, not just its messages

Keep private runtime state separate from the handle or startup data returned to
callers. Hide message constructors behind ordinary functions unless callers
legitimately need the protocol for integration.

Send operations that protect whole invariants. Prefer `Reserve(amount, reply)`
to a client-side `Get` followed by `Set` when interleaving would be incorrect.
Use plain snapshot reads where snapshot semantics are sufficient.

Separate application events from transport/lifecycle events. Use explicit
variants for user input, scheduled wakeups, worker results, stream events,
monitor notifications, and shutdown. Do not forge user messages for internal
wakes merely because an external API has a narrower message format.

Keep the owner responsive to the events it must service. Offload long jobs when
necessary, with bounded admission and appropriate supervision/monitoring.
Return compact work results and correlate them with run/request identity.
An `Effect` value does not itself mean work runs in another process.

Treat a reply containing `Result` separately from a fallible call transport. In
the inspected `gleam_erlang` API, `process.call` can panic rather than return a
timeout error. Verify the installed version and choose its supported failure
boundary; do not invent a `try_call` function.

Define what an acknowledgment means: accepted, applied, published, or durable.
A timeout does not prove work stopped. Cancellation needs a real protocol, and
late results need identity/generation checks. Include an owner-incarnation token
when identity could be reused after restart. Add idempotency or reconciliation
where retrying external effects could duplicate them.

Define overload behavior at the ingress, not only inside the actor handler.
Rejecting `Busy` after dequeue does not bound an already growing mailbox.
Specify admission limits, batching, coalescing, or demand as appropriate.

## 6. Share state without inventing guarantees

For a writer-actor/direct-reader hybrid, identify the authoritative state,
publish a complete snapshot in one appropriate operation, and let each logical
reader capture it once. Decide whether a successful write acknowledgment follows
publication. Define initialization, stale-read, and unavailable-owner behavior.

Do not assume a writer actor makes several ETS writes atomic to direct readers.
Do not implement concurrent read-modify-write as separate `cell.read` and
`cell.write` operations. Use a suitable atomic operation, an explicit retry
protocol, or owner serialization covering the full invariant.

Distinguish protected ETS from Cell's inspected **public** ETS implementation.
Single-writer discipline in an application is not a guarantee enforced by Cell.
Do not claim a snapshot is consistent when it contains independently mutable
handles, or when a logical read spans unrelated database/store operations.

Distinguish pool handles from checked-out transaction connections. Keep a
transaction's work on the supplied connection. Do not leak it beyond its scope
or assume queries through the original pool join the transaction. A failed row
decoder does not imply the SQL write did not happen.

Create resources in their intended owner. Passing an ETS ID to an actor does
not transfer table ownership. A parent-owned table may be correct when the
parent's lifetime is intentional; an actor-owned table belongs in its initializer
or a deliberate ownership-transfer protocol.

Design recovery for **handles as well as processes**. A stale PID subject or ETS
ID does not become valid when a child restarts. Choose refresh/lookup, grouped
restarts, ownership transfer, or another explicit recovery boundary. Choose
supervision strategy from dependencies, not habit.

Allocate a finite set of process names at application composition time, not per
request or inside repeatedly restarted initialization. Avoid unbounded atom
creation. Use direct subjects or a suitable dynamic registry where required.

Keep these BEAM-specific rules out of JavaScript-only designs. Encapsulated local
mutation in a foreign implementation can preserve an immutable API; it does not
justify exposing shared mutable objects to arbitrary callers.

## 7. Verify the behavior that matters

Run the project's supported equivalents of:

```sh
gleam format --check src test
gleam check
gleam test
```

Adjust paths to the project; do not create nonexistent test directories merely
to fit this command. Run each supported target when relevant. Check the local
CLI for version-specific options. Report missing tools or unrun checks honestly.

Test pure transitions and boundary decoders without infrastructure first. Then
exercise the applicable concurrency cases: initialization failure, owner death,
which children restart, stale handles, duplicate/late results, cancellation that
has not completed, timeout after an effect may have occurred, concurrent writers,
snapshot readiness, and overload. Use acknowledgments or monitors to control
ordering rather than treating a sleep as proof of synchronization.

Review FFI contracts and cleanup explicitly. Supervision, a typed signature, a
callback, and passing unit tests are not interchangeable guarantees.

Use [review and test cases](references/review-and-tests.md). For long-lived
session/event loops, read [the worked example](references/session-example.md)
and its original [core](assets/examples/session_core.gleam) and
[test cases](assets/examples/session_core_test.gleam). The bundled Gleam files
were source-reviewed but **not compiler- or runtime-verified** in this study.

## 8. Deliver a small, justified change

State the chosen ownership/consistency boundary, the important alternative not
chosen, and the tests actually run. For a review, prioritize correctness,
lifetime, and observable failure semantics before cosmetic style. Do not rewrite
an entire architecture or add a cache, actor, registry, or persistence layer
without a requirement that justifies it.

Consult [repository studies](references/repository-studies.md) for the 16-repo
comparison and counterexamples. Use [sources](references/sources.md) or the
[machine-readable ledger](references/source-ledger.json) for exact revisions and
reading scope. Treat upstream code as evidence, not infallible authority; check
local versions before borrowing an API or a behavior.
