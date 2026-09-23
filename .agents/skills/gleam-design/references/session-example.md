# Worked example: one owner, ordinary state, explicit work

## Contents

- Purpose and files
- Guarantees and deliberate policy choices
- Integrate with a runtime
- Add snapshots only when needed
- Extend without changing the model into a framework
- Verification status

## Purpose and files

Use this example to teach separation of domain transitions from process mechanics. It is original educational code inspired by the patterns studied, not copied from an upstream application and not a complete agent harness.

Read [session_core.gleam](../assets/examples/session_core.gleam) and [session_core_test.gleam](../assets/examples/session_core_test.gleam). The core uses only built-in types and returns `#(Model, List(Effect))`. Its tests call transitions directly; no actor or database is needed to reason about them.

The domain distinguishes `UserRequested(prompt)` from `ScheduledWake(tag)`. Both can request work without pretending a timer is a human message. The runtime may later translate these into a provider-specific representation, but the native event keeps its actual meaning.

## Guarantees and deliberate policy choices

The model tracks one active run, a monotonically increasing sequence within that owner incarnation, and three phases: `Idle`, `Running`, and `Stopping`.

A request while running or stopping is rejected as busy. This is a **domain admission policy**, not a bound on a BEAM mailbox. A real ingress still needs a queue/rate/admission policy before arbitrarily many messages accumulate.

Canceling enters `Stopping` and emits `AskJobToStop`. It does not immediately return to `Idle`, because asking a worker to stop is not proof it stopped. Another run is admitted only after a matching `WorkEnded` event. Repeated cancellation does not emit repeated stop effects.

A matching terminal event while stopping produces `ReportAbandoned`. This means the session no longer uses the result, not that external work was rolled back. The worker may have completed just before cancellation. Unknown, old, and duplicate terminal events leave the model unchanged.

The run ID combines an incarnation identifier with the local sequence. The runtime must supply a fresh incarnation identifier when an owner is replaced. A constant string reused on restart breaks this guarantee. This is an injected contract, not uniqueness magically supplied by the core.

This example makes the model opaque to protect transition construction, while exposing phase and protocol values for inspection and integration. It does not make the whole type system into an authorization boundary.

## Integrate with a runtime

Keep the runtime state small: the core model, the resources it really owns, and a dictionary from work IDs to worker/monitor information. Keep a single canonical model; do not synchronize a second JSON mirror after every event.

Use the following executor contract. It is deliberately architectural pseudocode rather than an invented Gleam library API:

```text
on a decoded domain event:
    next_model, effects = transition(current_model, event)
    adopt next_model
    interpret effects in their defined order

StartJob(id, reason):
    admit/start a bounded, appropriately supervised worker
    record its identity and monitor
    translate start failure into WorkEnded(id, Failed(...))
    arrange a terminal event even when the worker crashes

AskJobToStop(id):
    request cancellation through the worker's actual protocol
    apply the project's timeout/escalation policy if it cannot stop
    do not manufacture WorkEnded until the worker ended or another
    deliberately defined terminal condition has been established

worker completion or monitor-down:
    correlate to its work ID and incarnation
    clean up worker/monitor bookkeeping
    deliver WorkEnded(id, outcome) to the core

ReportFinished / ReportAbandoned / RejectBusy:
    notify the appropriate requester or observer
```

Resolve duplicate terminal signals from a normal result and a monitor notification. The core tolerates duplicates, but the adapter must also avoid leaked monitors and stale worker entries. Keep notifications correlated to requesters in the real protocol; `RejectBusy` is intentionally simplified here and does not itself identify a recipient.

Do not run a long provider call inside the coordinator merely because it has been wrapped as an effect. Use the installed OTP APIs and actual worker lifecycle. Avoid unlinked fire-and-forget work when the coordinator's recovery depends on knowing whether it is still running.

Treat model adoption and effect execution as non-transactional unless a durable design explicitly joins them. A crash after choosing a run but before starting its worker needs a recovery policy. Durable accepted jobs may require persisted work records, idempotency, or an outbox; a disposable interactive session may instead fail and restart. Do not add that machinery without the requirement.

## Add snapshots only when needed

Start with a status request to the owner or pass a snapshot to the one caller that needs it. Introduce direct shared reads when measured access patterns justify them.

A read-side projection can expose only current phase, run ID, progress, and revision rather than every worker handle or the full transcript. Publish it after the model transition at a documented point. Decide what readers see during initialization or owner replacement. A status snapshot should not accidentally grant write access or expose secrets.

Do not let the read-side projection become a second authority. A direct reader cannot reserve a new run simply by reading `Idle`; the authoritative operation must still decide whether to accept it.

## Extend without changing the model into a framework

For streaming, add chunk events with the active run ID and define bounds on retained data. For parallel tools, use a dictionary of pending call IDs and typed outcomes rather than an actor for each field. For timers, preserve timer identity/generation so superseded wakeups are distinguishable. Keep heterogeneous transport inputs mapped to explicit domain/runtime variants.

Choose a queue, replacement, or coalescing policy instead of busy rejection only when product semantics require it. Cancellation of external effects, completion of all workers, and user-visible abandonment are separate concepts; keep that separation when extending the state machine.

Do not claim replayability makes arbitrary function callbacks pure. The provided core is pure because it only manipulates values and returns effect descriptions. The executor is where resources, time, and failure belong.

## Verification status

The files were written and manually source-reviewed for the intended cases, but no Gleam compiler or Erlang runtime was available in the research environment. The nine test functions have **not been run**. They are examples to execute in the receiving project's toolchain, not evidence of a passing build.

Copy the core to an appropriate `src` module and the tests to the project's test tree, adjust the import if renamed, and use the project's existing test runner. Run formatting, compilation, and tests before adopting the example. No dependency manifest is supplied because inventing versions without a compiler would create a misleading runnable-project claim.
