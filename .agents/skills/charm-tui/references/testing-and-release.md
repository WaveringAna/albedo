# Testing and release

The [worked examples](../examples/WORKED-EXAMPLES.md) pair concrete changes with real regression tests. [Demo test instructions](../examples/worked/README.md) distinguish executed core tests from unexecuted Charm and terminal checks.

## Test the user contract in layers

Do not let a screenshot test stand in for state correctness, or a reducer test stand in for a terminal test. Choose the smallest layer that proves each property.

### 1. State and effect tests

Feed messages directly into the model. Assert state and the presence/absence of the next command. For asynchronous behavior, use controlled completions rather than sleeps. Execute simple commands in a fixture when useful; do not treat a composite batch as if it were one ordinary result.

Required cases for the relevant features:

| Contract | Adversarial sequence |
| --- | --- |
| Filter owns printable keys | Focus search; type `qjk/? `; app remains active and query changes correctly |
| Modal consumes once | Open modal; close with Enter/Escape; underlying selection does not activate |
| Latest query wins | Start A; type B; deliver A before B's debounce; ignore A |
| Stale failure is harmless | Complete B successfully, then fail A; keep B's success and rows |
| Cancellation is real | Cancel owner; blocked work observes context or declared shutdown policy |
| No empty acceptance | Filter to zero results; Enter, toggle, and navigation cannot index an item |
| Stable selection | Select an ID; refresh/reorder/filter; selection does not jump by index |
| Follow-tail respects reading | Scroll away; append output; anchor remains; jump-to-latest restores following |
| Retry remains usable | Fail an operation; retry; succeed without restarting the program |
| Output has a contract | Accepted/cancelled/error paths produce distinct intended stdout and statuses |

The [standalone contract exercises](../examples/contracts/README.md) cover several of these policies without Charm dependencies. They are not integration tests for any application.

### 2. Render and layout tests

Create deterministic model snapshots. For v2, inspect the root `View().Content` as appropriate; assert mode/cursor metadata separately. Freeze width, height, dataset, clock, operation state, theme, and animation frame. Normalize only values that are intentionally nondeterministic.

Test ordinary and hostile sizes. Suggested fixtures are `80x24`, `120x40`, `40x12`, `20x6`, `1x1`, and an initial `0x0` message. These are test inputs, not universal supported minimums. For every supported mode, verify the rendered cell bounds, valid cursor positions, body allocation, and visible essential actions. Below the declared minimum, verify the safe fallback and responsive cancellation.

Use display-width helpers for assertions. Add long paths, CJK, combining sequences, emoji, trusted ANSI styles, no matches, one item, and a large dataset. Explicitly test the effect of a wrapping footer and a prompt prefix.

A golden snapshot is a proposed visual contract. Review its changes like code. Do not repeatedly run an update flag until a regression becomes the expected result. Keep assertions for semantic state and dimensions alongside snapshots so a golden cannot silently bless a wrong action or overflow.

### 3. Program-level integration

Use the matching-major helper: `github.com/charmbracelet/x/exp/teatest/v2` for Tea v2, not the similarly named legacy module. The inspected v2 helper offers `NewTestModel`, `WithInitialTermSize`, `WithProgramOptions`, `Type`, `Send`, `WaitFor`, `FinalModel`, and `WithFinalTimeout`. [S14](sources.md#s14)

Wait for a specific state/output condition, send input, and use a bounded final timeout. Arrange cleanup even when an assertion fails. Check the final model's accepted/cancelled result, not merely whether some text appeared. Preserve the distinction between a simulated key event and a real bracketed paste or terminal signal.

When passing program options, verify which options the helper overrides. Pin color profile and terminal size where supported. Avoid recording a new golden for whatever capabilities happen to be present on a developer machine.

### 4. Real terminal / PTY checks

Run a real terminal or pseudoterminal flow to verify behavior that direct model tests do not establish: resize delivery, raw/canonical modes, restored cursor, alternate-screen exit, paste handling, interrupt, and child-process handoff. Test stdin data plus a terminal input source for pipeline commands. Check that diagnostic output does not corrupt either the screen or stdout's result.

For a targeted platform, use the terminal environments actually supported. A local truecolor terminal is not proof of correctness over SSH, in a multiplexer, or on another OS. Declare untested platforms rather than claiming all-terminal support.

VHS can script interaction, wait for screen content, capture frames, and generate textual/ASCII artifacts for regression review. Pin recording conditions and use assertions in the surrounding test workflow; producing a GIF alone is not a pass/fail test. [S15](sources.md#s15)

## Performance checks

Measure representative workloads and report units, data size, terminal size, and environment. Useful measurements include startup-to-interactive time, update/render duration, allocations per render, idle CPU, resize behavior, and memory growth during a long stream.

Use relative before/after comparisons on the same fixtures. Do not promise a universal millisecond threshold without a target system. Inject backend latency and failures to verify responsiveness while work is pending. Measure worst-case no-match filtering and heavy wrapping, not only a warm cache with a short query.

Run benchmarks in the target repository, for example:

```sh
go test ./...
go test -race ./...
go test -run '^$' -bench . -benchmem ./...
```

These commands may have platform, compiler, network, or fixture prerequisites. Report exact scope and failures. A race-test pass is useful evidence, not a mathematical proof that every schedule is safe.

## Release review

Before calling the UI finished, establish all applicable facts:

- The primary task works with the keyboard, and current help describes working controls.
- Acceptance, cancellation, errors, and interrupted work have correct outputs and cleanup.
- Normal and small layouts were inspected; zero-size and no-match states are safe.
- Light/dark or the deliberately supported theme, monochrome, and ordinary fonts remain understandable.
- Existing interaction and appearance were compared on fixed fixtures when behavior preservation was requested.
- No unnecessary dependency migration, configuration system, or component framework was introduced.

Use a delivery note with four short fields: **changed**, **preserved**, **verified**, **not verified**. Include actual command outcomes or terminal evidence. “Source-reviewed only” is more useful than an unsupported claim of production readiness.
