# Design and interaction

For a concrete build, use [the compact picker](../examples/WORKED-EXAMPLES.md#1-build-a-compact-picker). For a bug fix, use [the focus and modal walkthrough](../examples/WORKED-EXAMPLES.md#2-fix-search-keys-and-modal-fall-through).

These are design recommendations synthesized from the studied applications, not a mandatory Charm visual style. For observations and exact evidence, see the [case studies](case-studies.md).

## Design the smallest complete loop

Start with the user outcome, not the component catalogue. For a server picker the loop might be: identify candidates, narrow the set, inspect health, connect. Every persistent screen element should support one of those steps or explain the current state.

An inline prompt should leave the surrounding shell comprehensible. A full-screen browser can spend more space on context and inspection because the user intends to stay. Do not use a full-screen dashboard for a yes/no question or hide a complex monitoring workflow inside a one-line prompt.

Gum's filter supports an inline/fixed-height presentation and a full-screen branch. Its command wrapper also separates interactive rendering from result production. The transferable idea is a scoped interaction that remains useful in a larger shell workflow. [S06](sources.md#s06) [S07](sources.md#s07)

A useful design note before implementation is:

```text
Task: choose a server and connect.
Primary flow: type to filter -> move cursor -> inspect health -> accept.
Cancel: exit without emitting a server ID.
Output: one stable server ID, not the displayed label.
Preserve: existing search semantics, indicators, counters, animation, and keys.
Small layout: hide secondary columns; retain identity, health, and accept/cancel.
```

This is an example of the note's content, not a requirement to add a new file to every repository.

## Give the screen a reading order

A practical hierarchy is context first, work second, feedback third, controls last. Title and controls should be discoverable but not compete with the data.

An illustrative picker, not a prescribed theme:

```text
  Connect                                      2 of 18
  Filter: prod_

  > prod-api-01       ready          23 ms
    prod-api-02       connecting     --

  enter connect   esc cancel   ? help
```

The second number describes matching or total candidates only if that relationship is clear. Missing latency is not `0 ms`. A highlighted row is not automatically an accepted selection. While probing, allow the user to move or cancel; show pending work without pretending it has completed.

At a smaller width, simplify structure rather than scale all labels into fragments:

```text
 Connect  2/18
 > prod-api-01
   ready · 23 ms

 enter connect · esc cancel
```

Do not let an automatic switch discard the query, move the cursor to a different ID, or clear multi-selection.

## Make state readable without a legend

| State | Useful presentation | Common failure |
| --- | --- | --- |
| Initial load | What is loading and how to cancel | A spinner with no object or action |
| Refresh | Existing data plus refreshing/stale indicator | Blanking useful content every refresh |
| Truly empty dataset | What is absent and how to create/import/retry | “No results” with no context |
| No filter matches | Query context and a clear-filter action | An empty list that still accepts Enter |
| Recoverable failure | Operation, concise reason, retry/back | Full-screen fatal error for a transient issue |
| Destructive action | Exact target and consequence | A generic “Are you sure?” |
| Completed action | Stable confirmation or returned value | Disappearing feedback before it can be read |

Avoid boolean combinations that can accidentally render “loading,” “failed,” and “success” together. Model lifecycle states clearly, while retaining separate flags only for genuinely independent concerns.

Progress bars need a meaningful denominator. Otherwise use an activity indicator and useful counts or elapsed time. An animation should stop when its operation stops. Do not animate the entire screen to prove that it is alive.

## Focus is a spatial and behavioral promise

The focused control should be visually recognizable. The same visual emphasis should not mean focus in one place and danger in another. Multi-selection needs a separate mark from the cursor; keep marker widths stable so text does not jump between rows.

Define navigation per mode. An example policy is:

```text
Normal: arrows or j/k move; / enters search; Enter accepts current item.
Search: printable text edits; arrows may navigate results if documented.
        Escape leaves search; a subsequent Escape cancels the picker.
Modal: only modal controls react; closing restores previous focus.
```

This is not a universal keymap. A type-to-filter picker may start in search and never need a separate normal mode. Preserve an existing convention rather than force a Vim-like mode onto it.

Glow explicitly protects an active filter from its ordinary `q` quit action. Gum disables normal-mode navigation bindings while search is focused. Both are evidence that keyboard shortcuts must respect editing context. [S05](sources.md#s05) [S06](sources.md#s06)

Do not consume the same key both globally and locally. Enter that dismisses an error should not also open the first item. Escape that closes a dialog should not also quit the application. If Ctrl+C first cancels work instead of quitting, make that policy observable and test repeated presses.

## Teach controls at the point of use

Show the few likely actions near the active task; put the complete reference behind a help action. Derive both from actual enabled bindings where feasible. Hide or explicitly disable controls that cannot work in the current state.

Soft Serve's help depends on the active page and whether filtering is occurring; it also measures its rendered footer for layout. Help is an active part of the interaction and geometry, not a fixed decorative string. [S10](sources.md#s10)

Use action verbs: “open,” “connect,” “retry,” “clear filter,” “cancel.” “Submit” may be appropriate for a form, but it often says less than the actual operation. Show the target or scope for a destructive action. Reserve a persistent status area when frequent updates would otherwise make content move.

## Develop a theme from semantic roles

A small theme may define foreground, muted foreground, accent, border, focused row, selected mark, success, warning, and error. Derive component styles from these roles. Let a product's existing identity guide the actual colors.

Prefer the terminal's own background unless full-surface coloring serves a clear purpose. Check muted text on both light and dark backgrounds; “muted” must still be legible. Test a monochrome rendering: cursor marks, labels, and layout should preserve meaning after color disappears.

Borders consume cells and add noise. Use one around a coherent interaction, or a separator between independent regions, before boxing every field. Prefer padding inside a frame to margins that accidentally push content past it. Use bold or contrast for a few hierarchy levels, not every heading, badge, and value.

A mascot or accent animation can make a tool memorable. Keep it small, optional when appropriate, and separate from the user's input cursor. Do not remove an existing distinctive feature under the guise of code simplification; reduce implementation duplication rather than behavior.

## Accessibility and terminal-native operation

Keep the whole workflow usable with a keyboard and without special fonts. Use text alternatives for icons, color, and changing animation. Avoid stealing conventional copy/paste combinations without a strong reason. Mouse support should add convenience, not become the only way to reach an action.

A no-color TUI can still be difficult for assistive software because it repeatedly redraws and repositions text. Huh provides `WithAccessible(true)`, which changes interaction into ordinary prompts; that is a distinct capability from changing a palette. Offer a comparable plain or noninteractive path where the application needs one. [S11](sources.md#s11)

Treat confirmation, cancellation, and recovery as part of polish. A pretty interface that cannot be safely cancelled, piped, or read at a small size is not finished.
