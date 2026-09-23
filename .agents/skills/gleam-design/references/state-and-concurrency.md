# State, messages, and ownership

## Contents

- Classify the thing being passed
- Choose the consistency boundary
- Build a hybrid deliberately
- Trace lifetime and restart
- Handle work, timeouts, and overload
- Account for cost and target

Treat the recommendations below as design deductions from the source studies, not universal claims about every Gleam project. Source IDs resolve in [the source ledger](sources.md). Especially useful precedents: Packages [S01-S05], Cell [S06-S08], Gloogle [S24-S27], OTP [S09-S12], and Lustre [S21-S23].

## Classify the thing being passed

Distinguish five cases before proposing an actor or shared store.

**An immutable value:** pass configuration, parsed requests, a `Dict`, a syntax tree, or a snapshot as ordinary arguments. Updating a record produces another value; it does not update the caller's binding. Let a caller explicitly keep the returned state. Do not invent an actor just to make a record accessible.

**A resource handle:** a database pool, a `Subject`, a socket, or an ETS-backed cell refers to something with its own behavior. The handle can be immutable while operations through it cause effects. Read the implementation's concurrency and lifetime contract. A record containing handles is not a deep immutable snapshot of their referents.

**Actor-owned evolving state:** keep the current value in one process and replace it after each message. Choose this when decisions must be sequenced, the owner receives asynchronous events, or resources need a common lifecycle. The ordinary values inside that process do not each need their own process.

**A shared mutable store:** use ETS or a suitable library when multiple processes intentionally access one store. Identify the allowed writers and exact atomic operations. A typed `Cell(State)` does not serialize a sequence of `read`, computation, and `write`.

**Durable authority:** use a database or another deliberately durable system when recovery must retain facts. Neither a process nor ETS becomes durable because a supervisor restarts it. Distinguish a reconstructible index from irreplaceable accepted work.

Apply these distinctions to context records. Wisp's example captures a context in the request-handler closure [S16]. Pog distinguishes a pool reference from a checked-out connection behind one opaque public type [S19]. The first observation is not permission to share every possible handle concurrently.

## Choose the consistency boundary

Write the invariant first: for example, "inventory never falls below zero," "one active run per session," or "a reader sees a complete search-index generation." Then choose an operation that protects the entire invariant.

Do not implement a concurrent increment as:

```text
A reads 10
B reads 10
A writes 11
B writes 11
```

Each store access may be atomic; the increment is not. Prefer an appropriate atomic store operation, an explicit compare-and-retry protocol, or one owner handling `Increment`. For multi-key or durable invariants, use a transaction or another mechanism whose documented scope covers them. Do not assume `read_concurrency` or `write_concurrency` options strengthen correctness guarantees. [E01]

Design actor messages as domain operations when serialization matters. Prefer `Reserve(quantity, reply_to)` to separate public `GetQuantity` and `SetQuantity` calls. Two calls are two independently interleavable decisions. Keep ordinary getters where a snapshot is all the caller needs; do not ban reads categorically.

Do not confuse sequential handling with global atomicity. While an actor performs several ETS writes, direct readers can observe the intermediate store states. A writer actor serializes its own messages, not arbitrary readers or other writers.

Use API opacity to restrict which operations ordinary callers can perform. Do not treat opacity as a security sandbox or a runtime linearity guarantee. In a BEAM node, public ETS access and FFI can bypass a Gleam wrapper.

## Build a hybrid deliberately

Use **one write coordinator plus direct reads** when reads dominate, writes need ordering, and the consistency contract permits a published snapshot. Gloogle's type-search path is a concrete precedent: `Add` is an actor message, while search requests read the cell and traverse an ordinary recursive value [S24-S26].

For a stricter implementation, use this procedure:

1. Choose the authority: actor state, a database, or a recoverable source. Call the read-side value a projection when it is not authoritative.
2. Build and validate the next complete snapshot before publishing it. Store logically coupled data together when one-object publication matches the required invariant.
3. Publish in one documented atomic operation. Do not hide nested independently mutable handles inside a purported whole snapshot.
4. Define the acknowledgment point. Reply after publication when success promises read-your-write visibility; otherwise name the weaker guarantee.
5. Make each logical read capture one snapshot once. Multiple independent reads may legitimately observe different generations.
6. Define initialization, unavailable-owner, stale-read, rebuild, and shutdown behavior. Test these states explicitly.

Treat protected ETS as a possible enforcement mechanism for owner-only writes and direct reads. Cell's inspected implementation instead creates **public** ETS [S07]; single-writer behavior there is application discipline, not an access restriction imposed by the library. Do not silently substitute one guarantee for the other.

Consider publication cost. Replacing one enormous immutable index in a cell on each small update can copy substantial data. Alternatives include batching, a granular ETS design with weaker cross-key semantics, or performing queries in the owner and returning small results. Measure realistic read/write patterns before choosing.

For multi-table generation swaps, account for reclamation as well as publication. Swapping a pointer to a new table and immediately deleting the old table can break readers still using it. Avoid inventing a home-grown reclamation protocol unless the requirements warrant one; a single-value snapshot or owner-mediated query may be simpler.

Do not automatically call this architecture event sourcing or CQRS, or add an event bus. It can be one actor, one small store, and ordinary functions.

## Trace lifetime and restart

For every handle, answer: who creates it, who owns the underlying resource, who may use it, who closes it, and what happens when either party dies?

Creation location matters. Building an ETS table in a parent and passing its ID to `actor.new` does not transfer ETS ownership. To make the actor the owner, create the table in that actor's initializer or explicitly transfer ownership using a supported mechanism. A long-lived parent owning a table is also a valid design when chosen deliberately. [E01; S01, S25]

Distinguish three restart problems:

- A PID-backed subject still points at the old process after that process dies.
- A named subject can address a replacement, but sends during absence can still fail; it is not a durable queue.
- An old ETS table handle does not become the newly created table just because an actor restarts under the same name.

Choose grouped restarts, a stable lookup/indirection boundary, ownership transfer, or explicit capability refresh to match dependencies. With ordered dependent children, consider `RestForOne`; use `OneForAll` for genuinely coupled groups and `OneForOne` for independent failure. Validate the actual restart graph, rather than selecting the most reassuring name. OTP's tests assert which children restart [S11].

Create a finite set of `process.Name` values at application composition time and pass them down. Do not call `new_name` for every request, dynamic entity, or repeated child initialization: its implementation allocates atoms. For dynamic populations, use an appropriate registry or pass subjects directly; do not manufacture a registry when neither is needed. [S12]

Treat connection sessions differently from recoverable services. Glisten's connection factory uses temporary children [S14]; replaying a dead socket's old initialization is not the same as recovering a service. Decide whether a session should resume, reconnect, fail, or disappear.

## Handle work, timeouts, and overload

Keep a coordinator responsive to the events it must handle. Run long network, subprocess, or computation jobs in suitable workers when the owner must also accept cancellation, status, or other sessions' messages. A dedicated worker that does only one blocking task may correctly block; the rule is not "never block any process."

Track work identity and completion explicitly. Include a run or request ID, and where necessary an owner-incarnation token, in result messages. Ignore or classify stale completions. Do not reset an integer counter on restart and assume it still distinguishes old work from new work.

Separate three errors: domain rejection, dependency failure, and process/transport failure. A reply type such as `Result(Value, DomainError)` does not make `process.call` return a timeout as `Error`: the inspected API returns the reply directly and can panic on transport failure. Check the installed version before selecting a wrapper. [S12]

A timeout means the caller stopped waiting, not necessarily that the operation stopped. Cancellation also needs a real protocol. Where duplicate external effects matter, use operation IDs and an idempotency or reconciliation strategy at the authority. Do not retry a write merely because decoding its result failed: Pog explicitly performs the query before decoding returned rows. [S19]

Give every queue a policy: bounded admission, rejection, batching, coalescing, pull-based demand, or a justified upper bound. Checking `Busy` only after processing a message does not bound the mailbox of already queued requests. Track active workers, queue growth, work age, and rejected/coalesced work as appropriate. No blanket queue-size threshold is supplied here.

Retain timer identity or generation where obsolete timers can fire. Canceling a timer can be too late. Schedule after completion for non-overlapping periodic work; Packages' periodic worker uses that pattern [S04]. Choose fixed-rate scheduling separately when wall-clock cadence matters.

Do not mistake an effect description for an asynchronous execution primitive. Lustre separates update logic and effect callbacks, but the executor still determines execution context [S22-S23]. Keep durable effect delivery separate too: returning an effect list does not make the model update and external side effect atomic.

## Account for cost and target

Prefer compact work inputs and results over sending an entire evolving graph on every event. Ordinary BEAM message data is copied, with important exceptions for reference-counted binaries and literals on the same node; ETS object operations also involve copying. Preserve semantics first, then measure fan-out, copying, retained snapshots, and mailbox sizes. [E01-E02]

Use `persistent_term` only after establishing that updates are rare and accepting its update costs. It is optimized for reads; replacing complex values can induce VM-wide garbage-collection work. It is not a default store for changing sessions or per-token state. [E03]

Keep Erlang-specific ownership, ETS, names, and supervision rules out of JavaScript-only code. Stdlib's private JavaScript dictionary transients show another approach: tightly scoped mutation behind an immutable public API [S29]. That is not shared-memory actor coordination and not a general license to expose the transients. Preserve encapsulation and test each supported target.
