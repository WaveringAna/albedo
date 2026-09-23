# Architecture and effects

[Async search](../examples/WORKED-EXAMPLES.md#4-implement-latest-query-wins-search), [follow-tail behavior](../examples/WORKED-EXAMPLES.md#6-keep-a-streaming-view-from-jumping), and [subscription closure](../examples/WORKED-EXAMPLES.md#7-stop-subscriptions-without-leaks-or-busy-loops) now have complete implementations and regression tests.

## The useful boundary is ownership, not a model count

Bubble Tea separates state, message handling, effects, and rendering. Its command model lets work return a message without blocking interaction. [S01](sources.md#s01) [S04](sources.md#s04)

There are two useful composition patterns:

**Root plus child models.** A child owns a coherent reusable interaction, has its own update method, and returns a command. The root routes events, changes pages, and allocates space. Glow uses this approach for its listing and document view. [S05](sources.md#s05)

**Root plus imperative components.** The root owns event routing and calls methods such as `ScrollBy`, `SetItems`, or `SetFocused` on simpler helpers. Crush's UI guidance describes this pattern. The helpers need not each become a complete Elm-style model. [S08](sources.md#s08)

Choose the smaller approach that makes ownership legible in the existing project. Separate files can make a large update function readable without inventing an interface hierarchy. Extract genuinely independent interactions; do not create a component framework because a screen has several rectangles.

## Commands return facts; Update decides what they mean

An original integration sketch for v2:

```go
// Row is an application-owned immutable result value.
type loadedMsg struct {
    generation uint64
    rows       []Row
    err        error
}

// search must honor ctx; it must not read or write the live UI model.
func loadCmd(ctx context.Context, generation uint64, query string,
    search func(context.Context, string) ([]Row, error),
) tea.Cmd {
    return func() tea.Msg {
        rows, err := search(ctx, query)
        return loadedMsg{generation: generation, rows: rows, err: err}
    }
}
```

Imports are `context` and `tea "charm.land/bubbletea/v2"`. The surrounding application's model and `Row` type are intentionally not prescribed. This sketch is not a complete runnable program.

Capture query, ID, and configuration before constructing the closure. Copy mutable collections when the producer will continue changing them. A value-receiver method does not deep-copy maps, slices, or pointed-to objects. Returning a message is a transfer of ownership or a promise not to mutate the payload afterward.

Apply results only in the owning update path. For a child, retain **both** returned values:

```go
var cmd tea.Cmd
m.input, cmd = m.input.Update(msg)
return m, cmd
```

When other commands also need to run, collect them rather than overwriting `cmd`. Inspect methods such as `Focus`, spinner updates, and list updates for returned commands; silently dropping one can break blinking, loading, or deferred work.

Cheap synchronous transitions belong directly in Update. Setting `showHelp`, changing a focus enum, or moving an in-memory cursor rarely requires an asynchronous message round trip.

## Search, debounce, cancellation, and stale completions

Treat intent changes and request starts as different events. Correct ordering for latest-query-wins behavior is:

```text
query changes:
    increment generation immediately
    cancel previous in-flight context, if any
    record new query; invalidate any obsolete error/loading state
    clear rows or explicitly retain them as stale
    schedule debounce(generation), if debounce is justified

debounce(g):
    ignore unless g equals current generation
    begin one request with its own cancellable context
    set phase to loading

result(g, rows, error):
    ignore unless g equals current generation AND request is active
    release that request's cancellation resources
    apply success or failure; stop its activity indicator
```

Why invalidate before debounce? Request A can finish after the user types query B but before B's timer fires. Waiting until B starts leaves a window in which A is incorrectly accepted.

Guard errors and activity flags as carefully as rows. A stale failure must not replace fresh success; a stale completion must not stop the spinner for a newer request. A generation number is a UI correctness guard, not a resource limit: cancellation and bounded backend concurrency are still necessary.

Every new retry or refresh needs fresh identity even when the query text is unchanged. A user can leave and revisit the same screen; include the screen/session lifetime in the ownership scheme or ensure the generation survives that transition. On shutdown cancel the root context, reject further results, and wait for owned workers when their lifecycle requires it.

The [contract exercise](../examples/contracts/README.md) demonstrates intent invalidation and acceptance rules with deterministic tests. It does not test a real network backend or guarantee cancellation of code that ignores its context.

## Batch is concurrency, not dependency injection

`tea.Batch` runs independent commands without an ordering guarantee. `tea.Sequence` sequences command execution. Neither should be used to pretend that command B can read a model that command A has just updated: results still have to be processed through the event loop. [S01](sources.md#s01)

If B depends on A's returned ID, start B from the handler for A's result and capture the ID there. If two effects are independent, batch them. If the same mutable collection is shared, making execution appear sequential is not a substitute for an ownership policy.

Do not wrap cheap internal coordination in commands merely to make everything look asynchronous. Charm's command guidance explicitly distinguishes effects from internal message routing. [S04](sources.md#s04)

## Subscriptions and timers need lifetimes

For an external stream, a command can wait for one event and return a typed message. On receipt, process that event and return the next wait command. Handle channel closure as a terminal condition. Include cancellation in the wait; an unbounded receive can outlive the view or program.

Start only one consumer per intended subscription. Accidentally re-running `Init` on every refresh can create overlapping readers or tick loops. Cancellation ownership must remain at the screen/session/application level, not disappear when a local helper returns.

Glow's file discovery loop illustrates a one-event command that is re-armed by the update path and reports a closed channel separately. Its particular implementation is evidence for the pattern, not a production cancellation template to copy verbatim. [S05](sources.md#s05)

For custom timers, inject or model time in tests. A one-shot timer must be re-armed intentionally. Component timers have their own identity conventions; preserve them rather than inventing a second tick loop. Disable unnecessary activity while idle, hidden, or in a reduced-motion mode.

## Streaming and scrolling

Separate the durable event stream from the presentation rate. It is reasonable to coalesce redraw notifications or replace intermediate progress values; it is not reasonable to silently drop completed tool results, log records promised to the user, or state transitions.

Use explicit follow-tail state. When the user scrolls away, hold their anchor as new content arrives and show a new-output indication. A “jump to latest” action restores following. For variable-height items, preserve an item ID plus within-item offset when feasible rather than a brittle global line number.

Set a retention policy for long-running processes. Measure rendering cost for a large transcript and widths that cause substantial wrapping. Avoid repeatedly formatting the whole history or measuring its complete height to answer a yes/no overflow question.

Crush's inspected list has bounded overflow checks, width-dependent caches, and incremental prewarming. Its source differs from an older description in its own UI instructions about whether a list-level cache exists. Prefer code at the inspected revision over an architecture note when they disagree. [S09](sources.md#s09) [S08](sources.md#s08)

## Errors and side-effecting operations

A latest-query-wins policy is suitable for display-only search. It is not automatically suitable for writes. Cancelling a UI request may not cancel an operation already accepted by a server. Track durable operation IDs and reconcile status rather than calling a dismissed dialog proof of cancellation.

Prevent accidental duplicate submissions while a write is active. Make retry semantics explicit: safe repeat, idempotency key, or inspect-before-retry. Preserve enough context to explain which operation failed without exposing secrets in logs or terminal content.

Keep recoverable operation errors near the affected control. Reserve an application-fatal state for an inability to continue. Debug logs should go to a file or separate sink while the TUI owns its output stream.
