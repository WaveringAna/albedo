# Do by example: Charm TUIs

These are worked tasks, not extra rules to memorize. Each starts with a request, shows the change to make, and gives a check that can disprove it. The code is original teaching code informed by the [case studies](../references/case-studies.md), not copied application code.

Read the closest task, then open its complete source. Adapt the smallest relevant part to the target application's existing behavior. Do not replace a custom application with the demo. Main-loop and rendering APIs target the versions in [go.mod](worked/go.mod); check the target project's actual versions first.

**Execution boundary:** 26 tests against the actual dependency-free demo source files were executed, including cancellation and ring-buffer logic. The Charm adapters and their additional tests are supplied but were not compiled or terminal-run here because the required toolchain/dependencies could not be downloaded. See [verification](../VERIFICATION.md). The screen samples below are expected compositions, not captured terminal output.

| Task | Complete implementation |
| --- | --- |
| [1. Build a compact picker](#1-build-a-compact-picker) | [picker model](worked/cmd/picker/model.go) and [entry point](worked/cmd/picker/main.go) |
| [2. Fix search keys and modal fall-through](#2-fix-search-keys-and-modal-fall-through) | [routing](worked/cmd/picker/model.go) and [model tests](worked/cmd/picker/model_test.go) |
| [3. Fit a narrow terminal without losing identity](#3-fit-a-narrow-terminal-without-losing-identity) | [rendering helpers](worked/internal/display/render.go) and [bounds](worked/internal/display/bounds.go) |
| [4. Implement latest-query-wins search](#4-implement-latest-query-wins-search) | [request lifecycle](worked/cmd/search/request.go) and [Tea adapter](worked/cmd/search/model.go) |
| [5. Return a result without polluting stdout](#5-return-a-result-without-polluting-stdout) | [command boundary](worked/cmd/picker/main.go) and [result handling](worked/cmd/picker/selection.go) |
| [6. Keep a streaming view from jumping](#6-keep-a-streaming-view-from-jumping) | [ring history](worked/cmd/tail/history.go) and [view](worked/cmd/tail/model.go) |
| [7. Stop subscriptions without leaks or busy loops](#7-stop-subscriptions-without-leaks-or-busy-loops) | [producer/receive](worked/cmd/tail/stream.go) and [Tea adapter](worked/cmd/tail/model.go) |
| [8. Reduce code without redesigning the interface](#8-reduce-code-without-redesigning-the-interface) | [row renderer](worked/internal/display/render.go) and [render contracts](worked/internal/display/render_test.go) |

## Run the examples

From this skill's directory, in a terminal with a suitable Go toolchain and dependency access:

```sh
cd examples/worked
go mod tidy
go test -race ./...
go vet ./...
go run ./cmd/picker
go run ./cmd/search
go run ./cmd/tail
```

Run each demo separately; exit the current one before starting the next. There are no API keys, servers, deployments, or network calls in the demos themselves. Initial Go dependency resolution does need network access. `go mod tidy` creates the missing `go.sum`; the first download was not possible during authoring. Commit it when adopting these examples.

The picker and search are inline. The event monitor uses the alternate screen. The [demo README](worked/README.md) explains keys, scope, and the offline test command.

## 1. Build a compact picker

**Request:** “Let me pick a server. Keep it compact; return the server ID.”

**Make this, not a dashboard.** Start with one root model, a text input, a plain collection of items, a current-row index, and a final outcome. The supplied picker has five demo servers and no deployment operation. Selecting a server only returns its ID.

Expected composition at an ordinary width:

```text
choose a server
/ filter servers
> development                              eu · ready
  staging                                  eu · ready
  production                               eu · healthy
  東京 production                          jp · healthy
  queue worker                             eu · busy

5 matches
up up · down down · / search · enter choose · esc cancel · q quit
```

The precise spacing and help truncation depend on terminal width. The input placeholder is not a query. `>` indicates the current item, not a committed selection; there is no valid result until confirmation.

**Build the identity model first.** Store `{ID, Label, Detail}` once. Filter to indexes into that collection. When filtering, preserve the current ID if it still exists; otherwise select the first match. Never return the filtered-list index or the styled label as an ID. Here is the actual filter implementation:


```go
func (s *selection) filter(query string) {
	old, hadOld := s.current()
	s.visible = nil
	query = strings.ToLower(query)
	for i, row := range s.items {
		if strings.Contains(strings.ToLower(row.Label), query) {
			s.visible = append(s.visible, i)
		}
	}
	s.cursor = 0
	if hadOld {
		for i, index := range s.visible {
			if s.items[index].ID == old.ID {
				s.cursor = i
				break
			}
		}
	}
}
```


**Then connect the interaction.** In [model.go](worked/cmd/picker/model.go), `/` focuses the input; Escape or Enter returns to browsing without accepting anything; Enter while browsing opens a confirmation panel; Enter again commits the captured item. The root owns this routing. The input's returned command is always preserved.

**Do it.** Run `go run ./cmd/picker`. Move to `production`, press `/`, type `prod`, then press Escape. The same `prod-eu` item should remain current even though its visible index changed. Enter twice should produce exactly `prod-eu` on stdout. Repeat with a query having no matches: Enter must not invent a selection.

**Keep the test.** `TestFilterPreservesIdentity`, `TestDuplicateLabelsKeepDistinctIDs`, and `TestEmptyAndNoMatchesAreSafe` in [selection_test.go](worked/cmd/picker/selection_test.go) exercise this exact core code and passed offline. Add data replacement/sorting tests before adapting the example to a live catalog. Demo IDs are assumed unique; validate that at the application boundary for untrusted catalogs.

**Adaptation limit.** This is a single-select picker. Adding multi-select requires a separate set of selected IDs, explicit output ordering, and help for the toggle action—not overloading the current-row index.

## 2. Fix search keys and modal fall-through

**Request:** “Typing `q` in my filter quits. Escape from a dialog also leaves the page.”

A broken routing order often looks like this:

```go
// Wrong inside the root key handler: it runs before focus is considered.
if msg.String() == "q" {
    return m, tea.Quit
}
// ...only afterward does the editor receive the key.
```

**Move the ownership boundary, not the shortcut.** Keep `q` as the browse-mode quit key. First handle the explicit application interrupt. Next give a modal exclusive ownership. Next route editor keys. Only then process browse-mode actions. The actual picker modal branch is:

```go
if m.confirm != nil {
    switch msg.String() {
    case "esc":
        m.confirm = nil
    case "enter":
        m.result = outcome{Accepted: true, ID: m.confirm.ID}
        return m, tea.Quit
    }
    return m, nil // The closing Escape is consumed here too.
}
```

A dialog that closes itself must still consume that event. Do not continue into the underlying list because `m.confirm` has become nil.

The editor branch, also from the supplied root handler, is:

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

`k` comes from `m.keys()`, which changes both routing and help for the current mode. `m.updateInput` is not a placeholder; this is its complete implementation:


```go
func (m *model) updateInput(msg tea.Msg) tea.Cmd {
	before := m.input.Value()
	var cmd tea.Cmd
	m.input, cmd = m.input.Update(msg)
	if m.input.Value() != before {
		m.list.filter(m.input.Value())
		m.clampWindow()
	}
	return cmd // Never lose child effects, including cursor or paste commands.
}
```


Forward non-key child messages too: a paste result or cursor message does not necessarily arrive as a new keypress. The example uses a virtual cursor so it does not need real-cursor coordinate translation. With a real cursor, offset its coordinates by the rendered input's actual position. [API source](../references/sources.md#s17)

**Prove it.** [model_test.go](worked/cmd/picker/model_test.go) supplies `TestPrintableKeysBelongToSearch` (types `qj/k? ` into a focused input) and `TestModalEscapeDoesNotQuitOrReopen` (asserts no command or acceptance after closing the panel). These Charm-dependent tests were authored but could not be executed here. Run them against your dependencies, then try bracketed paste and ordinary typing in your supported terminal.

**Adaptation limit.** The demo only opens confirmation from browse mode, so focus is restored to the same blurred-input state. A dialog that can open from multiple controls must record and restore its previous focus owner; do not hardcode “focus editor” on close.

## 3. Fit a narrow terminal without losing identity

**Request:** “The last characters wrap inside my dialog, and the picker is unreadable when narrow.”

**Repair the arithmetic first.** This is the full helper used by the demos:


```go
func Panel(content string, outerWidth int) string {
	if outerWidth <= 0 {
		return ""
	}
	box := lipgloss.NewStyle().Border(lipgloss.NormalBorder()).Padding(0, 1)
	frame := box.GetHorizontalFrameSize()
	if outerWidth <= frame {
		return Line(strings.ReplaceAll(content, "\n", " "), outerWidth)
	}
	lines := strings.Split(content, "\n")
	for i := range lines {
		lines[i] = Line(lines[i], outerWidth-frame)
	}
	return box.Width(outerWidth).Render(strings.Join(lines, "\n"))
}
```


For its zero-margin style, two border cells plus two padding cells consume four columns. At `outerWidth = 40`, text has 36 columns; the box still receives `Width(40)`. Calling `box.Width(36)` would subtract the frame twice. The narrow fallback removes the frame instead of drawing an oversized border around zero-width content. This is specifically the Lip Gloss v2 contract, not a rule to paste into a v1 project. [Width source](../references/sources.md#s03)

**Then change composition before truncating identity.** The row helper keeps a two-column prefix in both states. At 48 columns and above it allocates a right-hand metadata column; below that it drops metadata. It clips by display cells using ANSI-aware helpers, after treating labels as plain data. [ANSI source](../references/sources.md#s17)

Expected narrow composition:

```text
choose a server
/ prod
> production
  東京 production

2 matches
```

Do not produce this instead:

```text
> product… eu · heal…
  東京 pr… jp · heal…
```

when dropping secondary metadata would allow the primary label to fit. Long identities may still require clipping; add an inspect view when users need the entire value before accepting.

**Allocate visible rows.** `model.bodyHeight()` measures the help it will actually render; the two explicitly single-line header rows and the one status row are tested layout contracts. The parent computes the body budget, and the renderer iterates only over the returned visible range. The shared `Window` helper is deliberately for fixed-height rows, not variable-height Markdown messages.

**Prove it.** [render_test.go](worked/internal/display/render_test.go) checks every width from 0 through 100 with ASCII, `東京サーバー`, combining accents, emoji, and long unbroken labels. It also asserts a 40-column panel actually measures 40 columns. Those Lip Gloss-dependent checks remain unexecuted here. The nonnegative bounds, visible-range invariants, and plain-text control neutralization tests did execute; do not confuse those with a terminal-width test.

**Do it.** Resize the picker to 80×24, 24×8, and a deliberately tiny size. It should switch to one clipped “resize” line rather than panic, overflow the frame, or become impossible to cancel. Mouse targets, if later added, must use the very same geometry.

## 4. Implement latest-query-wins search

**Request:** “My typeahead sometimes shows the previous query's result while I am still typing.”

**Reproduce this ordering explicitly:**

```text
A starts → user types B → A completes → B's debounce expires → B starts
```

The important event is “user types B,” not “B starts.” In the demo, the query change is processed synchronously through `searchState.change`:


```go
func (s *searchState) change(query string) ticket {
	s.generation++ // Invalidate A before B's debounce, not when B's I/O starts.
	if s.cancel != nil {
		s.cancel()
	}
	ctx, cancel := context.WithTimeout(s.root, 3*time.Second)
	s.cancel = cancel
	s.query = query
	s.phase = waiting
	s.rows = nil
	s.err = nil
	return ticket{ctx: ctx, generation: s.generation, query: query}
}
```


Its immutable `ticket` contains the context, query, and generation. The timer and backend command receive that ticket; neither reads the live model. Superseding a query cancels its timer or I/O immediately, and the three-second context bounds the intent lifetime. The fake backend honors cancellation. A real backend must do the same or enforce its own concurrency limits.

The command that calls the injected service is complete:


```go
func loadCmd(t ticket, search searchFunc) tea.Cmd {
	// The closure captures values and a service, never the live model.
	return func() tea.Msg {
		rows, err := search(t.ctx, t.query)
		return loadedMsg{generation: t.generation, rows: rows, err: err}
	}
}
```


`debounceMsg` is admitted only when its generation is current and its phase is waiting. `loadedMsg` is applied only when its generation is current and its phase is loading. Rejected results cannot change rows, errors, or the activity status. `ctrl+r` calls `change` even for identical query text, so a retry has fresh identity. The [full adapter](worked/cmd/search/model.go) handles all these messages and passes other events to the input.

**Keep this deterministic regression, not a sleep-based hope:**


```go
func TestOldResultDuringNewDebounceIsRejected(t *testing.T) {
	s := stateForTest(t)
	a := s.change("a")
	if !s.begin(a.generation) {
		t.Fatal("A did not start")
	}
	b := s.change("b") // B has NOT started I/O yet.
	if a.ctx.Err() != context.Canceled {
		t.Fatal("A wasn't cancelled immediately")
	}
	if s.complete(a.generation, []string{"old"}, nil) || s.phase != waiting || len(s.rows) != 0 {
		t.Fatal("A leaked through debounce")
	}
	if !s.begin(b.generation) || !s.complete(b.generation, []string{"fresh"}, nil) {
		t.Fatal("B rejected")
	}
	if s.rows[0] != "fresh" {
		t.Fatal("wrong rows")
	}
}
```


This test operates on the exact state implementation used by the demo, and passed. [request_test.go](worked/cmd/search/request_test.go) also checks stale errors, duplicate debounce admission, completion ownership, same-query retry, shutdown, and prompt cancellation of the timer/backend. [model_test.go](worked/cmd/search/model_test.go) adds adapter-level checks; these require Charm and remain unexecuted here.

**Do it.** Run `go run ./cmd/search`. Type `slow`, wait until “searching…” is visible, then edit to `queue`. The old answer must not flash during the new debounce. Enter `error` to exercise the recoverable error state; `ctrl+r` retries but deliberately fails again until the query changes. No network service or API key is involved.

**Adaptation limit.** This is read-only search, not a write-cancellation protocol. A dismissed dialog does not prove that a server cancelled a submitted deployment or payment. Use durable operation identity and reconciliation for writes.

## 5. Return a result without polluting stdout

**Request:** “I need to capture the choice in a script, but the UI's escape sequences end up in the value.”

The broken approach writes the interface or progress messages to stdout, then returns the currently highlighted item even after cancellation. Repair both boundaries.

**Choose the streams before starting the UI:**

```go
// main.go: stdout may be piped, but the demo requires terminal stdin/stderr.
final, err := tea.NewProgram(
    newModel(servers),
    tea.WithInput(os.Stdin),
    tea.WithOutput(os.Stderr),
).Run()
```

Do not add logging to that same stderr while the renderer owns it. Print diagnostics after `Run` returns or use a separate log file. The example does not silently open `/dev/tty`; unattended use must choose `--id` or `--list` instead. The terminal check happens before launching the program. [Terminal API source](../references/sources.md#s17)

**Only the final outcome may produce a result:**


```go
func finish(w io.Writer, result outcome) (int, error) {
	if result.Interrupted {
		return 130, nil
	}
	if !result.Accepted {
		return 1, nil
	}
	if result.ID == "" {
		return 2, fmt.Errorf("accepted result has no ID")
	}
	if _, err := fmt.Fprintln(w, result.ID); err != nil {
		return 2, err
	}
	return 0, nil
}
```


`finish` is called after the runtime has released the terminal. The ID comes from an accepted outcome, never from `cursor`. The demo uses explicit exit codes; retain your existing application's conventions rather than imposing these codes during cleanup.

**Do it, without any terminal interaction:**

```sh
go build -o picker ./cmd/picker
./picker --list
./picker --id prod-eu
```

The last command must output exactly:

```text
prod-eu
```

In Nushell, an ordinary capture is:

```nu
let server = (./picker --id prod-eu | str trim)
```

For interactive capture, omit `--id` while leaving terminal stdin and stderr available. Cancel and confirm in separate runs; cancellation must not return a valid-looking server ID. Reject invalid `--id` values before starting the TUI.

**Prove it.** `TestFinishNeverLeaksCancelledSelection` and `TestFinishReportsWriteAndInvalidResult` in [selection_test.go](worked/cmd/picker/selection_test.go) passed against the actual result function. They assert exact bytes, cancellation, keyboard-interrupt precedence, empty-ID rejection, and write-error propagation. The entry point's actual descriptor behavior still needs terminal testing.

**Adaptation limit.** `--list` is a plain machine-readable catalog, not a claim of screen-reader accessibility for the interactive picker. A numbered plain prompt or Huh's accessible path is a separate interaction decision.

## 6. Keep a streaming view from jumping

**Request:** “When I scroll up to read logs, each new line yanks me back to the bottom.”

The broken handler calls `GotoBottom` unconditionally after every append. Do not replace it with a timeout that guesses whether the user is reading. Store the intention explicitly.

The supplied monitor uses a bounded ring and logical sequence numbers. `top` points to a record identity, not a slice offset. Its append operation is:


```go
func (h *history) append(line string, height int) {
	h.buf[h.next%len(h.buf)] = line
	h.next++
	if h.next-h.first > len(h.buf) {
		h.first = h.next - len(h.buf)
	}
	if h.follow {
		h.top = h.bottom(height)
		h.unseen = 0
		return
	}
	h.unseen++
	if h.top < h.first {
		h.top = h.first
		h.expired = true
	}
}
```


While following, append moves the top to the tail. While reading, append leaves the anchor alone and increments the new-record count. If retention evicts the anchored record, move to the oldest remaining record and report that the anchor expired; pretending it is still the same content would be incorrect.

**Make “follow” an explicit action.** The monitor's `end` key calls:


```go
func (h *history) latest(height int) {
	h.follow = true
	h.top = h.bottom(height)
	h.unseen = 0
	h.expired = false
}
```


Scrolling down to the bottom also resumes following. A resize does not silently enable follow mode; the previous reading intent survives. The demo retains 32 single-line records, and the status reports eviction. It stores display history, not a durable audit log.

**Prove it.** `TestIncomingEventPreservesReadingAnchor` records the top and first visible line, appends a new record, and asserts that neither changed. Other [history tests](worked/cmd/tail/history_test.go) check ring ordering after 10,000 appends, eviction disclosure, follow restoration, resize, and zero-height windows. All six tests ran and passed on the same implementation used by the demo.

**Do it.** Run `go run ./cmd/tail`. Once the viewport overflows, press Up a few times. Incoming records should increase “new” without moving the text. Press End to catch up. Keep reading old output until retention evicts it; the status should say so. The synthetic stream eventually ends and the UI remains available for reading until quit.

**Adaptation limit.** These are single-line records. For wrapped messages, preserve item ID plus within-item line offset; calculate reflow without confusing record indexes and physical rows. A fixed record count also is not a byte bound for arbitrary-size messages—limit record size or add a byte budget before accepting untrusted streams.

## 7. Stop subscriptions without leaks or busy loops

**Request:** “After the stream closes, CPU spikes. Sometimes shutdown leaves a waiting goroutine.”

This pattern is broken:

```go
// Wrong: a closed channel immediately yields its zero value forever.
return func() tea.Msg { return lineMsg(<-ch) }
// If Update always schedules another wait, this becomes a busy loop.
```

**Turn closure into a terminal event.** The example's command waits for one event and distinguishes closure:


```go
func waitForLine(ctx context.Context, ch <-chan string) tea.Cmd {
	return func() tea.Msg {
		line, ok := receive(ctx, ch)
		if !ok {
			return closedMsg{}
		}
		return lineMsg(line)
	}
}
```


The underlying `receive` selects on both the data channel and context cancellation. The producer's sends also select on cancellation, and the queue is bounded. These are actual implementations in [stream.go](worked/cmd/tail/stream.go), not omitted TODOs.

**Re-arm in exactly one place:**

```go
case lineMsg:
    if m.ended {
        return m, nil
    }
    m.history.append(string(msg), m.rows())
    return m, waitForLine(m.ctx, m.events)
case closedMsg:
    m.ended = true
    return m, nil // No successor command after closure.
```

`Init` is called once for this subscription. Resize and navigation do not call it again. Quitting cancels the producer/consumer context and returns `tea.Quit`. The monitor does not bind that same worker context to `tea.WithContext`: otherwise cancelling workers as part of a normal quit can abort the program before its quit message is handled. Its `run` also defers cancellation for error paths. Search uses a different arrangement: the program's root context survives individual request cancellations.

**Prove it.** [stream_test.go](worked/cmd/tail/stream_test.go) passed tests for delivering the last buffered event before closure, unblocking a waiting receiver with cancellation, and producer shutdown. These tests use a timeout only as a deadlock guard. [model_test.go](worked/cmd/tail/model_test.go) also asserts that closure and later stale events return no command; this adapter test needs the unavailable Charm build.

**Adaptation limit.** A single listener is a lifecycle invariant, not enforced by the channel type. Do not start extra listeners in refresh paths. For a service with external resources, explicitly join its owned workers and close those resources; context cancellation alone is not proof that arbitrary backend code stopped.

## 8. Reduce code without redesigning the interface

**Request:** “Shorten the implementation, but keep my keys, layout, and custom look.”

**Start with a concrete equivalence boundary.** Suppose these are the two old row branches, after plain-text cleanup and for widths large enough for the prefix:

```go
if current {
    return lipgloss.NewStyle().Bold(true).Render("> " + ansi.Truncate(label, width-2, "…"))
}
return lipgloss.NewStyle().Bold(false).Render("  " + ansi.Truncate(label, width-2, "…"))
```

The correct reduction is to parameterize the repeated difference, not replace the picker with `bubbles/list` and inherit different spacing/help/keys. In the shared row helper the corresponding branch becomes:

```go
prefix := "  "
if current {
    prefix = "> "
}
// The same content budget, marker width, and selected style survive.
body := prefix + name
return lipgloss.NewStyle().Bold(current).Render(body)
```

The full [Row helper](worked/internal/display/render.go) also handles optional metadata and tiny widths. For the equivalence task above, pass empty metadata. Do not introduce that metadata column, new colors, borders, selection marks, or breakpoints as incidental cleanup in an existing UI.

**Prove the transformation at the right level.** [render_test.go](worked/internal/display/render_test.go) contains both the exact prefix/label contract and a byte-for-byte comparison with the previous two-branch renderer for sanitized labels. ANSI-stripped snapshots alone cannot detect changed styling. These rendering tests were authored but not executed here.

**Then reduce formatting work without changing the result.** This is the picker view's actual strategy:

```go
lo, hi := display.Window(len(m.list.visible), m.list.cursor, m.top, height)
for i := lo; i < hi; i++ {
    row := m.list.items[m.list.visible[i]]
    lines = append(lines, display.Row(row.Label, row.Detail, m.width, i == m.list.cursor))
}
```

The expensive row formatter sees only visible rows. `TestWindowFormatsOnlyVisibleRows` exercises the range used by this loop with 100,000 rows and a 12-row viewport; it passed. That establishes a bounded range, not a whole-application performance benchmark. Filtering still scans the sample collection when the query changes; do not claim virtualization made all work constant-time.

**Acceptance example:** “The row helper replaced the duplicated selected/unselected branches. Existing keys, marker, bolding, spacing, and return values remain the same. The equivalence test and before/after terminal capture were run.” Only say the last sentence after actually doing those checks in the target repository. For this bundle, terminal capture and Charm rendering remain unverified.

**Adaptation limit.** Do not chase line count by deleting help, error states, rendering distinctions, cancellation handling, or tests. A useful reduction preserves the observable contract and removes repeated mechanics.
