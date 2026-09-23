# Repository studies

## Contents

- Synthesis
- Applications: Packages and Gloogle
- Runtime libraries: OTP, Erlang, Glisten, Mist
- Function-first interfaces: Wisp, HTTP, Pog, SQLight
- UI and portable libraries: Lustre, stdlib, JSON
- Tooling: Squirrel and Birdie
- Small shared-state primitive: Cell
- Limits of the evidence

Read this as a comparison of selected implementation paths, not a ranking of repositories. The [source ledger](sources.md) records 36 files across 16 repositories, reading ranges, revisions, and five inspected test files.

## Synthesis

The strongest common lesson is not "use actors" or "avoid actors." It is to distinguish **ordinary data, a handle to a resource, and the authority that changes a resource**. The studied designs put these at different boundaries for different reasons.

Use a module to own an API and representation. Use a process to own time, asynchronous interaction, failure, or ordered decisions. Pass values and appropriate handles explicitly. Reach for shared state when its access pattern and consistency contract justify it. These recommendations are a synthesis; no single repository establishes a universal rule.

## Applications: Packages and Gloogle

### 1. gleam-lang/packages

**Observed:** Startup constructs storage and a `TextSearchIndex`, passes dependencies into request handling, and starts supervised periodic work. The opaque index contains an ETS bag handle, a typed cell holding known words, and a stemmer. Search combines store access with ordinary list/dictionary processing. The periodic actor stores a work callback and interval, then schedules its next run after the previous one completes. [S01-S05](sources.md#s01)

**Use:** Keep a background lifecycle in a process without routing all queries through that process. A domain module can expose straightforward functions even when it contains shared-store access.

**Limit:** The index is not a multi-operation transaction: package insertion and known-word updates are separate. The cell update reads a set, computes a new set, and writes it. Serialization assumptions and acceptable partial visibility need separate justification. Do not copy this as an atomic authoritative inventory design.

### 2. ghivert/gloogle

**Observed:** `jupiter.gleam` composes a PostgreSQL pool, HTTP server, periodic workers, and a search worker. Context initialization creates the cell table; the search worker initializes and updates its value. `Add` travels through the actor, while search requests read the published `TypeSearch` value directly. The index itself is a recursive structure of records, dictionaries, options, and lists. Lookup can also consult PostgreSQL. [S24-S27](sources.md#s24)

**Use:** Separate write coordination from query execution. A tree does not need a process or mutable cell for every node. Request-specific context updates can stay ordinary record updates.

**Limit:** Cell permits public writes, so this is not runtime-enforced single-writer access. HTTP starts before the search worker, making initial readiness a real design question. The code also uses unsafe name coercions; prefer supported typed naming APIs in new code. A cell read is not a transaction spanning the subsequent database queries.

## Runtime libraries: OTP, Erlang, Glisten, Mist

### 3. gleam-lang/otp

**Observed:** An actor builder takes state, a callback, and initialization behavior. `Started(data)` distinguishes the supervised process PID from data returned to the caller. An initializer can choose its selector and returned data. The loop carries ordinary state forward through `Next`. Tests exercise initialization failures, timeouts, selector replacement, and distinct supervision restart strategies. [S09-S11](sources.md#s09)

**Use:** Design the process API separately from its private state. Initialize owned resources in the intended owner. Test the dependency/restart graph through observable lifecycle events.

**Limit:** A subject is only one possible startup result, and supervision alone does not preserve old resource handles or durable facts. Do not infer that every stateful module belongs in a supervisor. Do not imitate tiny test timeouts without considering the execution environment.

### 4. gleam-lang/erlang

**Observed:** Subjects encode an owner/tag or a name. Selectors map different message sources into one typed payload. Names use atoms and are documented for creation at startup. `call` returns the reply directly; timeout or missing/failed callee can panic. Monitors and timers are explicit mechanisms. [S12](sources.md#s12)

**Use:** Keep typed message protocols at process boundaries. Map foreign or heterogeneous events once, then pattern-match on your own event type. Distinguish a reply's domain error from transport failure.

**Limit:** A typed subject is not a liveness guarantee. A name is not a durable mailbox. New names on every request or child restart are not a harmless allocation pattern. Selectors and monitors do not eliminate the need to reason about cleanup and late messages.

### 5. rawhat/glisten

**Observed:** An acceptor accepts a socket, starts a connection child, transfers the controlling process, and sends `Ready`. The connection actor keeps transport state and user state together while giving callbacks ordinary values. Internal socket events and custom user messages have distinct variants. Connection children use a temporary restart policy. [S13-S14](sources.md#s13)

**Use:** Make a process boundary follow a real resource lifecycle. Keep protocol machinery separate from user-domain messages. Make ownership handoff explicit before enabling event delivery.

**Limit:** This is transport infrastructure, not a template for putting all application functions behind actors. The inspected handler catches callback crashes and continues with old state, and some returned selector values are ignored. Do not assume those behaviors are appropriate for transactional application logic or infer guarantees from type names alone.

### 6. rawhat/mist

**Observed:** A public facade exposes response variants, body-reading operations, and an opaque next-step type. The internal handler uses `Http1` and `Http2` variants containing the state relevant to each protocol. It captures dependencies in a callback and dispatches between protocol-specific modules. Body reading changes `Request(Connection)` into `Request(BitArray)`. [S17-S18](sources.md#s17)

**Use:** Express mutually exclusive protocol states with variants, and preserve type relationships across transformations. Hide transport-specific details behind a useful public boundary without forcing every helper into a process.

**Limit:** A consumption callback can operate on a live socket and is not necessarily pure or replayable. The independently inspected Mist and Glisten revisions do not imply that their current public APIs are mutually compatible; verify the consuming project's manifest.

## Function-first interfaces: Wisp, HTTP, Pog, SQLight

### 7. gleam-wisp/wisp

**Observed:** Responses are ordinary typed values. The database example creates a connection, puts it in an application context, and partially applies the request handler with that context. It does not introduce a new application actor just to distribute the context. [S15-S16](sources.md#s15)

**Use:** Make dependency passing boring. Let handlers call domain functions with the required handles, and keep request/response transformations straightforward.

**Limit:** This example establishes the shape of dependency injection, not the concurrency guarantees of every possible database connection or the behavior of `tiny_database` internals. It is not evidence that all handles can be shared without qualification.

### 8. gleam-lang/http

**Observed:** `Request(body)` is a public record. `set_body` and `map` can change the body type while preserving request metadata. Header and URI helpers use ordinary transformations. Tests construct values directly and assert conversion behavior, including absent and malformed query data. [S28](sources.md#s28), [S35](sources.md#s35)

**Use:** Make valid relationships generic rather than introducing a family of disconnected DTOs. Use public constructors when callers are meant to assemble records. Test pure behavior without starting infrastructure.

**Limit:** A public record also permits callers to bypass helper conventions. Choose an opaque constructor when a domain invariant really requires it; public data in a protocol library is not a universal argument against opacity.

### 9. lpil/pog

**Observed:** The opaque connection type represents either a pool name or a checked-out connection. A query carries typed parameters and a row decoder. Transactions check out one connection, defer its check-in, and roll back on callback failure or panic. Tests check commit, error rollback, panic rollback, decoder mismatch, and timeout behavior. [S19](sources.md#s19), [S36](sources.md#s36)

**Use:** Pass shareable pool handles without adding another serializing actor by default. Carry a result decoder in a query builder. Keep transaction work on the supplied connection and clean up deliberately.

**Limit:** Do not leak or concurrently reuse a checked-out connection merely because its public type is also `Connection`. Calling the original pool inside the callback does not automatically use that transaction. A decode failure occurs after the SQL ran and is not proof the mutation did not happen.

### 10. lpil/sqlight

**Observed:** One typed public API bridges Erlang and JavaScript implementations. Query results pass through a `Decoder(t)`. The inspected `with_connection` implementation opens a connection, calls a callback, then closes on the normal return path. [S20](sources.md#s20)

**Use:** Keep external representations behind a small typed adapter. Read both the Gleam declaration and foreign implementation when concurrency or failure guarantees matter.

**Limit:** `use` syntax does not itself ensure cleanup if a callback crashes. The inspected helper is not equivalent to Pog's explicit crash cleanup. No claim about arbitrary concurrent access to a SQLight connection is established by this source sample.

## UI and portable libraries: Lustre, stdlib, JSON

### 11. lustre-labs/lustre

**Observed:** The public architecture links model, message, update, view, and effect types. The Erlang server runtime stores ordinary application state within an actor, while its own protocol distinguishes client events, effect-produced domain messages, subscriptions, monitors, and shutdown. Subscriber bookkeeping is ordinary dictionary/set state. Effects contain callbacks; the runtime invokes the effect executor. [S21-S23](sources.md#s21)

**Use:** Separate domain transitions from runtime transport and lifecycle events. Use a pure transition boundary where it makes testing useful. Keep collections of subscribers or pending work as data unless each needs a separate lifecycle.

**Limit:** An effect is not inherently an independently scheduled job. The inspected server runtime is Erlang-specific; do not assume those implementation details describe the JavaScript runtime. Nor does a returned effect guarantee durable, exactly-once execution.

### 12. gleam-lang/stdlib

**Observed:** The dictionary module presents an immutable API. Its JavaScript implementation path uses private transient dictionaries with explicit single-use discipline. Dynamic decoding composes typed field readers and reports accumulated errors through the final `run` boundary. [S29-S30](sources.md#s29)

**Use:** Distinguish a stable public semantic contract from internal implementation technique. Keep mutation tightly scoped where it is justified, and keep dynamic inspection at a clear typed boundary.

**Limit:** The transient discipline is documented internally, not a general linear-type guarantee offered to application code. Do not expose those operations or use a native mutable object as shared state without a separate ownership design. Cross-target decoding behavior deserves tests.

### 13. gleam-lang/json

**Observed:** `parse` accepts a decoder and returns typed output. Syntax errors and inability to decode the desired shape have distinct variants. Erlang and JavaScript details are handled behind target-specific functions and FFI. [S31](sources.md#s31)

**Use:** Turn boundary data into the intended type once and keep downstream code typed. Make error categories correspond to actions a caller can take.

**Limit:** Successful JSON syntax parsing is not domain validation. Do not serialize already typed local values merely to move them across a module boundary, and do not assume a type signature establishes foreign-runtime behavior without inspection.

## Tooling: Squirrel and Birdie

### 14. giacomocavalieri/squirrel

**Observed:** Value identifiers and type identifiers are distinct opaque types with checked constructors. Structured type variants replace loosely organized strings. The PostgreSQL inference path carries a single connection and ordinary dictionary caches in a context, then threads that context through its computation abstraction. [S32-S33](sources.md#s32)

**Use:** Validate representations at construction boundaries and make illegal combinations harder to express. Keep local cache evolution as local data rather than inventing an actor per cache.

**Limit:** The inspected identifier constructor checks particular lexical rules; do not assume that proves every conceivable code-generation constraint. A state-threading abstraction is not a recommendation to add that dependency for every small function. Network-facing code here still performs IO.

### 15. giacomocavalieri/birdie

**Observed:** Internal snapshots use a phantom status parameter, so new and accepted snapshots appear distinctly in comparisons and outcomes. Snapshot IO, content comparison, serialization, and diagnostics remain identifiable responsibilities. The implementation deliberately defers expensive source analysis to review rather than doing it for every snapshot assertion. [S34](sources.md#s34)

**Use:** Use types to distinguish values with identical storage but different valid roles. Sometimes a better phase for expensive work is simpler than adding a concurrent cache.

**Limit:** The root file is large; file length alone is not an architecture verdict. Cached global-helper calls appear in the code, but their implementation was not audited here. Neither parallel-test safety nor global cache semantics is inferred from those calls.

## Small shared-state primitive: Cell

### 16. lpil/cell

**Observed:** A generic opaque cell couples a table with a reference. The FFI uses a public ETS set and turns missing/destroyed-table operations into errors. The inspected test covers empty cells, replacement, deletion, differently typed cells, and dropping the whole table. [S06-S08](sources.md#s06)

**Use:** A compact typed handle can expose intentionally shared, occasionally replaced values without a bespoke message protocol for every read.

**Limit:** Tests of sequential operations do not establish atomic read-modify-write. This implementation supplies individual operations, not transactions or compare-and-swap. The table lifetime remains tied to its ETS owner. For local algorithmic state, prefer ordinary immutable structures unless a measured requirement justifies mutation.

## Limits of the evidence

No repository was audited in its entirety. No benchmarks, deployments, upstream test suites, or compiler checks of the bundled original example were run. Concrete conclusions above come from inspected source paths; recommendations additionally use the official Erlang and Gleam semantics in [E01-E05](sources.md#e01).

Do not convert every observed choice into a rule. This study intentionally retains counterexamples: public records beside opaque types, large facades beside focused modules, direct shared-store reads beside actor messages, and local mutation behind immutable interfaces. Use the smallest design that meets the actual contract.
