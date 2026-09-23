---
name: charm-tui
description: Design, implement, review, and refine Go terminal interfaces using Charm's Bubble Tea, Bubbles, Lip Gloss, and Huh. Use for interactive CLIs, pickers, forms, dashboards, streaming views, keyboard/focus bugs, terminal layout, or Charm API migrations. Emphasizes behavior-preserving changes, terminal-native interaction, correct asynchronous state, and restrained visual design. Also use to decide whether a full-screen TUI is appropriate; do not add Charm to ordinary noninteractive Go commands without a need.
---

# Charm TUI craft

Build a terminal tool that is easy to understand, quick to operate, and reliable under real input, data, and terminal conditions. Learn Charm's interaction and engineering practices, not just its palette.

## Work from an example

Open [Do by example](examples/WORKED-EXAMPLES.md) and choose the closest task before inventing a new pattern. Each task pairs a concrete user request with before/after code, the full implementation, a sequence to try, and a regression test. Use the example's mechanism; preserve the target application's contract.

For a new picker, begin with [task 1](examples/WORKED-EXAMPLES.md#1-build-a-compact-picker). For an existing application, jump directly to [focus and modals](examples/WORKED-EXAMPLES.md#2-fix-search-keys-and-modal-fall-through), [cell-aware layout](examples/WORKED-EXAMPLES.md#3-fit-a-narrow-terminal-without-losing-identity), [async search](examples/WORKED-EXAMPLES.md#4-implement-latest-query-wins-search), [pipeline output](examples/WORKED-EXAMPLES.md#5-return-a-result-without-polluting-stdout), [stream anchors](examples/WORKED-EXAMPLES.md#6-keep-a-streaming-view-from-jumping), [subscription closure](examples/WORKED-EXAMPLES.md#7-stop-subscriptions-without-leaks-or-busy-loops), or [behavior-preserving reduction](examples/WORKED-EXAMPLES.md#8-reduce-code-without-redesigning-the-interface).

### Example: fix the owner of a key, not the key

Given “typing q in search quits,” do not remove the browse-mode q shortcut. In the key handler, route to the focused input before considering browse bindings. This is an excerpt from the [complete picker](examples/worked/cmd/picker/model.go); `k` is its mode-specific keymap:

```go
if m.input.Focused() {
    if key.Matches(msg, k.back, k.accept) {
        m.input.Blur()
        m.clampWindow()
        return m, nil
    }
    return m, m.updateInput(msg)
}
```

The modal branch precedes this and consumes its key even when closing. The browse branch follows it. Keep `TestPrintableKeysBelongToSearch` and `TestModalEscapeDoesNotQuitOrReopen`, adapting their setup rather than merely repeating the rule.

### Example: invalidate before waiting

Given “old results flash during debounce,” change the generation when the query changes. Then test the precise race, using the state implementation from [the search program](examples/worked/cmd/search/request.go):

```go
a := s.change("a")
s.begin(a.generation)
b := s.change("b") // B has not started yet.
if s.complete(a.generation, []string{"old"}, nil) {
    t.Fatal("accepted an old result during the new debounce")
}
s.begin(b.generation)
```

The full example also cancels A's context, tags errors, rejects duplicate starts, and retains child input commands. The regression is in [request_test.go](examples/worked/cmd/search/request_test.go).

### Example: preserve the allocated box width

Given a 40-column dialog using Lip Gloss v2, with zero margins:

```go
box := lipgloss.NewStyle().Border(lipgloss.NormalBorder()).Padding(0, 1)
outerWidth := 40
innerWidth := outerWidth - box.GetHorizontalFrameSize()
content := ansi.Truncate(label, innerWidth, "…")
rendered := box.Width(outerWidth).Render(content)
```

Do not feed `innerWidth` back into `box.Width`: it already includes the internal frame. The [complete helper](examples/worked/internal/display/render.go) handles tiny widths by removing the frame, and the supplied rendering test measures actual output. Use cell-width assertions, not byte-length assertions.

These example fragments are version-specific excerpts, not independent complete programs. The [three complete programs](examples/worked/README.md) supply imports, models, entry points, and tests. Read [verification](VERIFICATION.md) before repeating any claim that they were compiled or terminal-tested.

## Start with the existing contract

Before editing, inspect `go.mod`, the entry point, the root model, keybindings, styles, output handling, and relevant tests. Run the existing UI when possible. Record its main task, normal flow, cancellation behavior, output format, and supported environments. For a new tool, derive these from the user's request.

Treat an existing interface as a contract. Preserve its keys, focus behavior, inline/full-screen mode, sizing, counters, custom visuals, and result semantics unless the requested change requires otherwise. Replacing a bespoke picker with a stock `bubbles/list` is not a behavior-preserving cleanup. Reuse component mechanics beneath the interface when useful.

Identify the repository's actual Charm major versions. Do not paste v1 examples into v2 code, upgrade dependencies as incidental cleanup, or assume every Charm package uses the same module path. Read [versions and component selection](references/versions-and-components.md) when selecting libraries, writing version-sensitive code, or migrating.

## Choose the smallest suitable surface

| User's task | Starting point |
| --- | --- |
| Run once, return a value, integrate into scripts | Flags plus ordinary output; styling is optional |
| Pick, confirm, or enter a few values | Inline interaction; Huh for forms, Gum for shell composition |
| Browse, inspect, filter, or monitor repeatedly | Bubble Tea application with appropriate Bubbles |
| Read formatted prose | Glamour plus a viewport when scrolling is needed |
| Operate through SSH | A session-scoped TUI; investigate Wish only when remote interaction is actually required |

These are choices, not mandatory layers. A command need not gain a configuration framework, router, event bus, or full-screen shell to become pleasant. Preserve the project's CLI conventions; use ordinary Go functions and structs before adding infrastructure.

## Design the interaction before decorating it

Write the primary flow in one sentence: “Filter candidates, inspect the current item, then accept or cancel.” Identify the first useful action and make it visible without opening help.

Distinguish **focus** (which control receives input), **cursor** (which item is highlighted), **selection** (which IDs have been chosen), and **operation state** (what work is happening). Do not overload one field or one color with these meanings.

Define loading, ready, empty, no-match, recoverable-error, and terminal-error states where applicable. Give each a truthful message and a useful next action. Preserve valid data during refresh when it remains useful; label it as refreshing or stale. Do not turn every transient failure into an empty screen.

Use a compact hierarchy: task/context, primary content, local status, contextual controls. Start with the terminal's background, readable text, one accent role, a clear current-row marker, and quiet metadata. Add borders only where they clarify grouping. Personality can live in a title, status wording, or small animation; it must not displace content or obscure state.

Do not impose a pink palette, rounded boxes, gradients, a large logo, or dashboard cards merely because the task mentions Charm. Read [design and interaction](references/design-and-interaction.md) for concrete patterns and tradeoffs.

## Keep state ownership obvious

The model's update path owns mutable UI state. Commands perform I/O or expensive work and return typed results. Rendering describes the current state; it does not initiate network requests, start timers, or secretly change the user's selection.

Use either a small tree of independently useful components or one root model with simple imperative helpers. Both are legitimate. Extract a component when it owns a coherent interaction or lifecycle, not for every rectangle. A local state change does not need a command that sends a message back to the same model.

When forwarding an event to a Bubbles component, retain both its returned model and command. Do not broadcast keystrokes to every child. Route non-input results to their owner even when that owner is not visible, when the lifecycle requires it.

For asynchronous work:

- Capture inputs before returning a command. Do not let the command read or mutate a live model, slice, or map concurrently.
- Cancel superseded work and tag results with a generation or operation ID. Invalidate the old generation **when intent changes**, not only when the next request starts. Ignore obsolete successes, failures, and completion flags.
- Use `tea.Batch` for independent work. Start result-dependent work from the matching result handler; command ordering is not a data dependency.
- Give timers, subscriptions, and workers an owner and a stop condition. Re-arm a one-shot subscription only once. Stop on channel closure. Bound backlog and work.

Read [architecture and effects](references/architecture-and-effects.md) for the precise request lifecycle and streaming policy. The [search walkthrough](examples/WORKED-EXAMPLES.md#4-implement-latest-query-wins-search) wires this into an actual input model; the smaller [contract examples](examples/contracts/README.md) isolate the arithmetic/state rules.

## Route input deliberately

Set precedence explicitly: emergency/application-level controls, then the active modal or popup, then the focused control, then the current screen's unconsumed navigation keys. The exact interrupt policy is application-specific; document whether it cancels work, backs out, or exits.

Printable characters belong to an active editor. Typing `q`, `j`, `k`, `/`, `?`, or space must not trigger unrelated navigation or quit. Preserve component editing, paste, cursor, and focus commands. Handle a modal's consumed key exactly once; closing it must not activate the item underneath.

Use `key.Binding` and `help.Model` when appropriate so active controls and displayed help share definitions. Disable unavailable actions in both routing and help. Escape should unwind a visible interaction predictably; do not unexpectedly discard a draft. Restore focus after closing overlays.

Keyboard operation must remain complete without a mouse. Mouse hit testing must use the same geometry as rendering. Keep ordinary terminal selection/copy practical; do not enable aggressive mouse capture without a use case. Do not silently take over the clipboard.

## Treat layout as cell arithmetic

Let the parent allocate bounds. Measure rendered headers, prompts, help, and status at the current width; subtract them from available space. Clamp derived dimensions. Keep margins, borders, padding, and child content separate. Never depend on a fixed “subtract 4” unless those four rows are a tested invariant.

In **Lip Gloss v2**, `Width(n)` describes the block including borders and padding, before margins. Do not subtract a frame twice. Details and a worked example are in [layout and rendering](references/layout-and-rendering.md).

Measure display cells with the relevant Lip Gloss/ANSI helpers, not `len`, byte slicing, or rune counts. Account for styled content, CJK, combining marks, emoji, tabs, prompts, and selection prefixes. A helper that preserves ANSI is not a security sanitizer.

On narrow terminals, drop optional columns or switch composition before making the primary task unusable. Keep a compact safe view for extremely small dimensions and handle initial zero-size events. Reflow on width changes; clamp or preserve the scroll anchor intentionally. At ordinary sizes, controls should not jump as counts or status strings change.

## Make output and lifecycle part of the UI

For a pipeline-oriented command, reserve stdout for its machine-consumable result. Use stderr or an explicitly chosen terminal for interaction, and print the final result only after the UI has finished. Do not mix logging with a live renderer, even on stderr if that is the renderer's output.

Define noninteractive behavior before opening a terminal. Do not hang CI waiting for a key. Distinguish accepted, cancelled, failed, and interrupted outcomes; cancellation must not accidentally emit a valid-looking selection. Respect existing exit-code conventions.

Let the runtime restore terminal modes. Return through cleanup paths; avoid `os.Exit` before deferred cleanup. Use the runtime's supported handoff for an interactive child process instead of letting two programs read the same terminal. For SSH, keep model, theme/capability state, cancellation, and authentication boundaries session-scoped.

Offer a plain or accessible path when relevant. No-color mode is not equivalent to screen-reader accessibility. Avoid reliance on a special font, animation, mouse, terminal graphics, or color alone.

## Optimize the work, not the appearance of work

First measure startup, keystroke-to-update responsiveness, rendering cost, allocations, and idle CPU for representative data. Keep inexpensive local filtering simple. Move expensive search/render work out of the update/render path when measurements justify it.

For large lists, avoid formatting all rows just to display one viewport. Cache costly Markdown or highlighting with explicit data, width, and theme invalidation. Do not compute full-history height every frame merely to decide whether content overflows. A cache has a correctness contract and a memory cost; do not add one reflexively.

For streams, coalesce redraws without silently dropping durable data. Follow new output only while the user is following the tail; reading older content must not be interrupted by incoming events. Bound history or make its retention policy explicit.

## Verify the contract, then finish

Read [testing and release](references/testing-and-release.md). At minimum test state transitions and command results, focus and modal routing, zero/one/many/no-match data, stale completion, resize, Unicode, and stdout separation. Include direct model tests; use the **matching-major** teatest package for integration where suitable.

Inspect actual terminal output at a normal size and a small size. For existing UIs, compare before and after on the same input. Exercise paste, cancel, error recovery, repeated refresh, light/dark or explicit-theme behavior, and terminal restoration. Use deterministic snapshots or VHS recordings for appearance; they complement behavioral assertions, not replace them.

Use [evaluation scenarios](evals/scenarios.json) as adversarial review prompts, selecting relevant cases. These are evaluation specifications, not a claim that the target application has passed.

When delivering work, state the interaction preserved or changed, the implementation choices that mattered, the checks actually run, and any unverified terminal behavior. Distinguish source-reviewed, compiled, unit-tested, and terminal-tested. Do not claim polish from compilation alone.

## Evidence and further reading

The [case studies](references/case-studies.md) separate observed application behavior from recommendations, including a concrete example where implementation and maintainer notes disagree. The [source ledger](references/sources.md) records primary sources, inspected revisions, and scope. This skill is an independent synthesis, not an official Charm standard.
