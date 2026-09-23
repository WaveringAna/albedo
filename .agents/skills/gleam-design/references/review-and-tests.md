# Review and test cases

## Contents

- Review a change
- Select tests by the changed guarantee
- Evaluate an agent using this skill
- Record verification accurately

## Review a change

Trace the new behavior through input, state, side effects, and recovery. Look for an invariant that the implementation does not actually protect. Treat style preferences as secondary unless they obstruct that reasoning.

Ask these questions in order:

1. **State:** Is this a value, a resource handle, actor-owned state, a shared store, or durable authority? Are multiple supposed sources of truth kept consistent?
2. **Type boundary:** Can callers represent an invalid phase or swap unrelated IDs? Do decoders check the actual boundary, including domain constraints?
3. **Operation:** Is the claimed atomic unit a single operation, several calls, several tables, or several systems? Is the guarantee documented at that scope?
4. **Lifecycle:** Who owns resources, who closes them, what is restartable, and who still holds obsolete handles afterward?
5. **Execution:** Does the owner remain responsive? Does an effect callback really offload work? What prevents unbounded queued work?
6. **Failure:** What is acknowledged, what may already have happened after timeout, and what makes retry safe?
7. **Evidence:** Which tests demonstrate these claims? Which remain assumptions?

Use the inspected tests as styles of evidence, not complete coverage: Cell checks sequential table behavior; HTTP checks pure transformations and invalid input; OTP checks initialization/selectors and restart membership; Pog checks commit and error/panic rollback. [S08, S10-S11, S35-S36 in the ledger](sources.md)

## Select tests by the changed guarantee

| Change | Important test | Do not accept as equivalent |
| --- | --- | --- |
| Pure domain transition | Expected new state and effect descriptions for each meaningful event | Only a full integration smoke test |
| New decoder or smart constructor | Missing, malformed, boundary, and domain-invalid values | One valid example |
| Actor protocol | Request/reply identity, domain rejection, transport failure, selector reachability | Compilation of the message type |
| Shared counter/update | Force two writers to observe the same old value; verify required result | Repeating one sequential write many times |
| Snapshot publication | Read before initialization, during update, after acknowledgment, and during rebuild | Only reading after startup settles |
| Supervision change | Kill the relevant child; assert exactly the dependent set restarts and handles recover | Asserting a supervisor PID exists |
| Worker cancellation | Cancel while work is running; send late completion; confirm state policy and worker termination | Sending a cancel message and immediately assuming success |
| External write retry | Simulate timeout/response loss after commit; check idempotency or reconciliation | Treating timeout or decode error as rollback |
| Database transaction | Verify commit, callback error rollback, panic cleanup, and correct connection use | Only checking the callback's returned value |
| Admission/backpressure | Drive input beyond service rate and check queue/rejection/coalescing behavior | A `Busy` branch after dequeue |
| Cross-target FFI | Exercise representation and cleanup on each supported target | Passing Erlang tests for a JavaScript deployment |

Use barriers, typed acknowledgments, and monitors for controlled interleavings. Keep deadlines bounded and reasonably tolerant of CI scheduling. Ensure test processes, tables, connections, and files are cleaned up. Where termination can bypass ordinary cleanup, test the actual owner/OS/resource behavior rather than assuming callback cleanup runs.

For property-oriented tests, consider: old generation results do not change current state; terminal results do not apply twice; a rejected request does not mutate authority; snapshot metadata and payload refer to one generation; pure transformations preserve the original value. These are suggested properties, not claims that every upstream project already tests them.

## Evaluate an agent using this skill

Use these prompts as **unexecuted evaluation cases** for a future agent or reviewer. They are not a benchmark score and no separate agent evaluation was run for this package.

### Case A: The actor-per-module request

**Prompt:** "Split this Gleam HTTP app into ConfigActor, ValidatorActor, JsonActor, and UserRepositoryActor so every module owns its state."

**Expected:** Inspect existing code and requirements. Keep configuration and validation as ordinary data/functions. Pass an appropriate database handle. Introduce a process only for a real coordination or lifecycle need. Explain the smaller design without refusing useful refactoring.

**Failure:** Generate the four actors because the language targets BEAM.

### Case B: The apparently safe cell increment

**Prompt:** "Each request reads an Int cell, adds one, and writes it back. The cell is typed and ETS is concurrent, so approve this."

**Expected:** Show the lost-update interleaving. Select an atomic increment, owner operation, or other correctly scoped mechanism. Distinguish an individual cell operation from a multi-step update.

**Failure:** Add a sleep, a concurrency flag, or a type annotation and call it fixed.

### Case C: The read-heavy derived index

**Prompt:** "A background worker rebuilds an index occasionally; thousands of handlers query it. Put every query through the worker to avoid all shared state."

**Expected:** Consider ordinary published snapshots/direct reads, with writer discipline, readiness, publication scope, copying cost, lifetime, and tolerated freshness specified. Compare owner queries if the index is huge or stronger semantics are needed. Do not insist on either mechanism without the contract.

**Failure:** Universal actor-only dogma, or unqualified global mutable state.

### Case D: The restarted table owner

**Prompt:** "The supervised actor recreated its ETS table, so all existing request-handler contexts still have a valid table handle."

**Expected:** Trace the obsolete ID and the restart dependency graph. Propose appropriate refresh/lookup, grouped restarts, or ownership/lifetime changes and test them.

**Failure:** Claim that retaining a typed handle keeps the original table alive or redirects it to the replacement.

### Case E: The hidden execution context

**Prompt:** "I moved a thirty-second function into an Effect callback. Now my coordinator can process cancellation concurrently."

**Expected:** Inspect the executor. Offload to a suitable bounded worker only if needed. Track worker identity and results; do not infer concurrency from a wrapper type.

**Failure:** Claim the callback or `use` expression automatically runs asynchronously.

### Case F: The SQL write with a bad row decoder

**Prompt:** "The INSERT returned a decoding error, so retrying the INSERT cannot duplicate anything."

**Expected:** Separate query execution from row decoding. Determine whether a transaction rolled back, whether the write committed, and whether a stable operation key or reconciliation is required.

**Failure:** Treat all `Error` values as proof no external effect occurred.

### Case G: The scope illusion

**Prompt:** "This `use conn <- with_connection(...)` guarantees closure on all failures, and I can send conn to a detached worker for later use."

**Expected:** Read the helper implementation and resource contract. Check exception paths and lifetime; do not leak scoped connections. Explain that callback syntax provides neither automatic cleanup nor ownership transfer.

**Failure:** Promise RAII/finally semantics from syntax alone.

### Case H: The small JavaScript utility

**Prompt:** "Refactor this JavaScript-target Gleam list transformation using the skill."

**Expected:** Improve the function/types/tests as needed without ETS, OTP, an ownership ledger in the user-facing answer, or new framework scaffolding.

**Failure:** Apply BEAM runtime architecture to a pure helper.

## Record verification accurately

In a real implementation response, report which format, compile, unit, integration, and target checks actually ran. Distinguish a reviewed test source from an executed test, a package-structure validator from a Gleam compiler, and an inferred risk from a reproduced bug.

The current research inspected upstream test source but did not execute upstream suites. The bundled example is original educational code, not an audited production runtime. Compile and run it against the receiving project's toolchain before adopting it.
