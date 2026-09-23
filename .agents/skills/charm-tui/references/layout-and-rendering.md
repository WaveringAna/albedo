# Layout and rendering

See [the responsive layout walkthrough](../examples/WORKED-EXAMPLES.md#3-fit-a-narrow-terminal-without-losing-identity) for complete row/panel helpers and tests, and [the refactor walkthrough](../examples/WORKED-EXAMPLES.md#8-reduce-code-without-redesigning-the-interface) for behavior-preserving changes.

## Allocate actual rectangles

For each component, define whether an input size means total allocation or content area. Prefer parent-owned total allocations and named helpers for frame arithmetic. Rendering, clipping, scrolling, and mouse hit testing must agree on the same bounds.

Compute header/footer heights from their rendered content at the current width. Help may wrap; an error may add a line; a prompt has a visible prefix. Subtract actual chrome before allocating the body. Do not subtract a nominal height and then render additional lines outside it.

Use a defined tiny-terminal strategy when the chrome alone cannot fit. It may be a compact status or “resize to continue” view, but cancellation should remain responsive. Initial zero dimensions must not panic or trigger expensive rendering with invalid widths.

Read-only layout values can be recalculated cheaply. Expensive reflow belongs behind explicit invalidation rather than happening on every spinner tick. A height-only resize need not invalidate width-dependent text wrapping.

## Lip Gloss v2 box arithmetic

The v2 API defines `Width(n)` as block width before margins; padding and borders consume space within that width. The frame helpers include their documented frame constituents, so distinguish internal frame from external margins. [S03](sources.md#s03)

A worked example with **zero margins**:

```go
// v2 integration sketch. caller guarantees outerWidth >= the frame width.
box := lipgloss.NewStyle().
    Border(lipgloss.NormalBorder()).
    Padding(0, 2)

outerWidth := 40
innerWidth := outerWidth - box.GetHorizontalFrameSize() // 40 - 6 = 34
child := ansi.Truncate(label, innerWidth, "…")
rendered := box.Width(outerWidth).Render(child)
```

Imports: `charm.land/lipgloss/v2` and `github.com/charmbracelet/x/ansi`. In this particular zero-margin style the frame is the two border cells plus four padding cells. **Do not call `box.Width(innerWidth)` after subtracting the frame**; that makes the outer box smaller a second time.

With external margins, use explicit arithmetic:

```text
allocated width = external margins + border-box width
content width   = border-box width - borders - padding
```

Alternatively remove margins from the inner component style and let the parent own spacing. If the terminal is narrower than the frame itself, omit the decorative frame or choose the tiny view; clamping content to zero does not make an oversized border disappear.

Apply the same distinction to height. Confirm rendered dimensions in tests, including long unbroken tokens and styled child strings. A requested width is not permission to skip checking the actual output under the target version and configuration.

## Use terminal cells, not source-string length

Bytes, Unicode code points, grapheme clusters, and terminal cells are not interchangeable. ANSI control sequences add bytes without normal visible width. East Asian characters, combining marks, and emoji further separate those measures.

Use `lipgloss.Width`/`Height` to measure styled blocks and `ansi.StringWidth`, `ansi.Truncate`, or `ansi.Cut` for display-aware operations. For editing, use the component's text handling rather than reimplementing cursor motion with byte offsets. The ANSI helpers are documented to handle escape sequences and display-width operations. [S03](sources.md#s03) [S16](sources.md#s16)

Do not feed a fuzzy library's byte offsets directly into a display-cell range API. Gum explicitly converts match positions before styling the display. That is evidence for a general rule: track each API's index unit and convert deliberately. [S06](sources.md#s06)

Useful fixtures include:

```text
ASCII: prod-api-01
CJK: 東京サーバー
Combining: é
Emoji: 👩‍💻
Wide path: /very/long/unbroken/component/name/with/no/spaces
ANSI: the same labels with application-owned styling
```

The combining example contains an `e` followed by a combining accent. Include tabs, a trailing newline, multi-line data, and mixed-direction text when those inputs are relevant. Terminal/font width disagreements can remain; test supported environments instead of asserting that every emoji occupies a universal width.

## Keep style, data, and control sequences distinct

Store canonical labels and IDs separately from their decorated form. Styling should not change the identity used for selection, sorting, filtering, or output. Do not sort ANSI-decorated strings or return the currently rendered row as a machine ID.

ANSI-aware clipping preserves control sequences; that is useful for trusted styles, but it is **not a security policy for untrusted text**. Before displaying remote names, logs, or filenames, decide how to handle control characters and escape sequences. Prefer plain-text data with application-owned styling. When accepting third-party ANSI, use an explicit allowlist rather than assuming color-preserving helpers neutralize terminal commands.

Apply styles to logical segments consistently. When composing already styled text, test resets and background continuity; an embedded reset can change following text. Prefer semantic reusable styles to scattered numeric color literals.

Color detection and output encoding belong at the terminal boundary. In v2, Lip Gloss styles produce full-fidelity output and downsampling happens at the output layer; Bubble Tea handles it for its own renderer. For standalone styled output, use the documented writer helpers. [S03](sources.md#s03)

Use a reasonable theme before a background-color response arrives, then update through the event loop. Do not synchronously read terminal input from View to discover a color. Session-specific terminal capabilities must not become mutable global state in an SSH service.

## Responsive composition beats indiscriminate truncation

Choose an explicit priority for available width. A repository browser might retain the name and status, drop the author column, shorten dates, then switch from side-by-side detail to a separate view. A picker might shorten metadata before its primary identity.

When clipping identity is unavoidable, provide an inspect action or detail region with the full value. Prefer a stable primary column and aligned metadata over irregular badges. Keep truncation style consistent; do not make selected text wider merely because its prefix changed.

Measure a pane once and give the same result to its viewport, renderer, and hit regions. For overlays, clamp the dialog to the current viewport, subtract its internal frame once, and draw it last. Resize should not preserve stale mouse rectangles.

## Hot-path budgeting

Expensive syntax highlighting and Markdown conversion do not belong in an unconditional View call. Recompute on relevant data, width, or theme changes, then render cached results. Protect asynchronous rendering with the same generation rules as search.

A render cache must specify its key, invalidation events, maximum retained size, and whether results can be shared. Text width, theme, content revision, expansion state, focus/highlight, and selection overlays may all affect output. Cache only the stable layer when a cheap dynamic overlay changes each frame.

Crush's inspected list invalidates its render cache on width change and keeps it on height-only changes. Its complete-height computation is cached but still potentially expensive after invalidation; its overflow path can stop early. The lesson is to ask the smallest question needed, not to copy an entire chat-list subsystem into a small picker. [S09](sources.md#s09)

Benchmark representative data and a resize/scroll sequence before adding virtualized layout or a screen-buffer renderer. Simple string composition is a good default. Ultraviolet or layered composition can be appropriate for complex overlays and rectangular drawing; adopt it because the application needs those capabilities, not because another Charm app has them.
