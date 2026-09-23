# Types, modules, and control flow

## Contents

- Organize by responsibility rather than process count
- Spend types on meaningful distinctions
- Keep dynamic data at explicit boundaries
- Compose functions without obscuring execution
- Refactor in small verified steps

Use the source studies as examples, not a mandatory directory template. Resolve source IDs in [sources.md](sources.md).

## Organize by responsibility rather than process count

Start with a cohesive module. Split it when callers need a smaller API, a representation needs protecting, a target boundary appears, or logic has a distinct reason to change. Do not split because every file must be short, because a noun exists, or because another language's framework has a `Service` class.

Observe the range of designs. Wisp, Mist, Pog, and Birdie expose substantial root modules, while implementation details live in helper or `internal` modules [S15, S17, S19, S34]. Gloogle separates startup, context, write coordination, and the search representation [S24-S27]. Follow the existing project's coherent choice instead of enforcing one universal layout.

For a growing event-driven service, consider this **illustrative**, not required, shape:

```text
src/app.gleam                  startup, configuration, supervision
src/app/session.gleam          domain state and transitions
src/app/session/runtime.gleam  actor protocol, workers, timers, monitors
src/app/provider.gleam         external requests, response decoding
src/app/store.gleam            persistence contract and codecs
src/app/web.gleam              request/response boundary
```

Keep core types in their owning module. Import or re-export them where needed; avoid parallel definitions for the same canonical record. Introduce a shared protocol module only when several modules genuinely share that contract. Do not create a catch-all `types.gleam` and import the whole application through it.

Pass the narrow dependency needed by a helper. A context is useful at the composition boundary; it need not become a service locator passed into every pure function. Keep request-specific data, such as trace IDs, as record updates rather than mutations of global context. Gloogle's `set_trace_id` illustrates this [S25].

## Spend types on meaningful distinctions

Use a public record for data callers are allowed to assemble. Use an opaque type when callers must go through constructors or when the representation should remain replaceable. Do not make every record opaque by reflex.

Give an opaque wrapper a stated invariant. Squirrel's value and type identifiers use different constructors and validation rules [S32]. Distinct IDs are also useful when accidentally swapping two IDs would be expensive. A type alias improves readability but does not create a distinct nominal type.

Prefer variants to correlated flags and optional fields. Mist's protocol state is `Http1(...) | Http2(...)`, putting protocol-specific data with the corresponding alternative [S18]. For a job, prefer `Queued`, `Running(run_id, worker)`, and `Completed(result)` to unrelated `is_running`, `worker: Option`, and `result: Option` fields. Do not force a giant sum type where independent dimensions really are independent.

Use type parameters to preserve actual relationships. Examples include `Request(body)` changing its body type through a transformation [S28], `Query(row)` carrying the decoder for its output [S19], and runtime types connecting model and message types [S21-S23]. Prefer these relationships to a loosely typed map plus casts.

Use phantom states sparingly when identical representations have distinct valid uses. Birdie distinguishes `Snapshot(New)` and `Snapshot(Accepted)` in its internal comparison and serialization functions [S34]. The parameter is not proof of runtime resource ownership; construction and conversion boundaries still matter.

Expose handles through small functions when callers should not depend on message constructors. An opaque handle around a typed subject can keep command constructors private. Expose the protocol deliberately when composition with selectors or another integration actually requires it. Do not leak all runtime internals merely to enable a getter.

## Keep dynamic data at explicit boundaries

Decode JSON, database rows, and foreign-runtime values into domain types at the boundary. Keep `Dynamic` inside the adapter rather than propagating it through the application. Preserve useful error information such as the failing field, provider, operation, or constraint.

Follow the shape of `json.parse(input, decoder)` and Pog's decoder-bearing query [S19, S31]. Separate malformed transport data from validly encoded but invalid domain data. A shape decoder still needs domain validation for constraints such as nonempty IDs, allowed ranges, or valid state transitions.

Do not serialize native in-process values to JSON and back merely to cross a module or local process boundary. Add codecs when crossing a real wire or persistence boundary. Keep a wire DTO separate only where its schema genuinely differs; do not invent a second mirror of every internal type.

Audit FFI declarations as contracts. Check the actual return shape, whether failure throws or returns, process affinity, ownership, blocking behavior, and supported targets. An `@external` signature does not verify the foreign implementation. Keep unsafe coercions small, documented, and outside ordinary business logic. Gloogle's name-coercion shortcut and stdlib's private transient operations are not general application patterns to imitate. [S24, S29]

## Compose functions without obscuring execution

Use pipelines for readable data transformation. Use `case` for meaningful branching and `use ... <- result.try(...)` for a sequence of fallible steps. Keep expected failures as values; reserve assertions for programmer invariants or explicitly fatal startup conditions. An assertion on a known valid literal is different from one on an arbitrary user request. [S32]

Read `use` as callback syntax. Ask how often the callback runs, when it runs, and what happens if it fails. It is not intrinsically early return, async/await, exception protection, or resource cleanup. Compare SQLight's normal-path close with Pog's explicit deferred check-in and crash rollback. [S19-S20; E04]

Use folds or recursion when threading state is the operation. Squirrel carries a connection plus ordinary dictionary caches through a stateful computation abstraction rather than spawning a process per cache [S33]. Do not introduce that abstraction for a two-step function where returning `#(state, result)` is clearer.

Treat a pure transition plus an effect interpreter as an option, not a compulsory framework. It is useful for replayable tests and state machines receiving many event kinds. An ordinary request handler that performs a query and returns a response often needs only well-factored functions.

A function-valued field or callback may perform IO. "It is just a function" does not establish purity. Similarly, an immutable builder can describe future effects without executing them; make construction, start, and execution distinct in the API when it helps callers reason about lifecycle.

## Refactor in small verified steps

First name the invariant and extract pure transformations without changing execution context. Next make dependency arguments explicit. Then tighten types and decoders at boundaries. Only after that, change process ownership or introduce shared access, with failure tests around the change.

Preserve public behavior, typed validation, and persistence formats unless the task calls for changing them. Do not remove a validation boundary because internal callers currently appear typed. Do not replace a working local value with a global cell to avoid passing one argument.

Finish with the smallest coherent patch. Explain what changed in ownership or guarantees, not just how many files were reorganized.
