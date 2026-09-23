# Versions and component selection

## Resolve the repository before choosing an API

Research snapshot: **2026-09-23**. The inspected published documentation showed Bubble Tea **v2.0.9**, Bubbles **v2.2.1**, and Lip Gloss **v2.0.6**. This records what was inspected, not a promise that those are permanently the newest releases or an instruction to upgrade a working project. [S01](sources.md#s01) [S02](sources.md#s02) [S03](sources.md#s03)

Start with the repository's `go.mod`, `go.sum`, `go.work` if present, and source imports. Follow the installed APIs and existing conventions. Check each dependency's Go/toolchain requirement before proposing changes. Module resolution may need network access; do not silently modify the module graph just to inspect it.

Useful local checks, when the repository and dependencies are available:

```sh
go version
go list -m all
go test ./...
```

Use a focused import search as well. Multiple versions can legitimately appear in a dependency graph, but v1 and v2 Tea model/message/component APIs cannot be casually interchanged in one implementation.

For an existing v1 application, fixing a focus bug does not require migration. For an explicit migration, move the interdependent Tea/Bubbles/Lip Gloss layer together, adapt the relevant tests, and verify behavior before optimizing. Bubbles' upgrade guide expressly calls for the companion upgrades. [S02](sources.md#s02)

## High-impact v1/v2 differences

| Area | Legacy shape | v2 shape to verify in the target version |
| --- | --- | --- |
| Tea import | `github.com/charmbracelet/bubbletea` | `charm.land/bubbletea/v2` |
| Bubbles import | `github.com/charmbracelet/bubbles/...` | `charm.land/bubbles/v2/...` |
| Lip Gloss import | `github.com/charmbracelet/lipgloss` | `charm.land/lipgloss/v2` |
| Root view | `View() string` | `View() tea.View`, often using `tea.NewView(content)` |
| Alternate screen | Program options / imperative commands | `View.AltScreen` |
| Mouse mode | Program options / imperative commands | `View.MouseMode` |
| Ordinary key switch | `case tea.KeyMsg:` for a concrete key event | Usually `case tea.KeyPressMsg:`; `tea.KeyMsg` is now an interface |
| Key content | Legacy type/rune representation | `Code`, `Text`, modifiers; separate press/release concepts |
| Space matching | Often a literal space | `String()` uses `"space"`; prefer current key-binding conventions |
| Paste | Legacy key-message conventions | Dedicated paste messages; preserve input component handling |
| Many component dimensions | Public fields | `SetWidth`, `SetHeight`, `Width()`, `Height()` as applicable |
| Viewport creation | `viewport.New(width, height)` | `viewport.New(viewport.WithWidth(w), viewport.WithHeight(h))` |
| Several default keymaps | Mutable package variables | Constructors such as `DefaultKeyMap()` |
| Colors | `lipgloss.Color` as a string type | `lipgloss.Color(...)` returns `image/color.Color` |
| Adaptive color | Root `AdaptiveColor` | Explicit `LightDark` or compatibility package |
| Lip Gloss renderer | Renderer-associated styles | Value styles; output-layer color handling |

This is a triage map, not a replacement for the full upgrade guides. Refer to [S01](sources.md#s01), [S02](sources.md#s02), and [S03](sources.md#s03). Do not mechanically convert unrelated packages that retain a `github.com/charmbracelet/...` module path.

An original minimal v2 **method sketch**, not a standalone application:

```go
func (m model) View() tea.View {
    v := tea.NewView(m.renderContent())
    v.AltScreen = m.fullScreen
    return v
}
```

For background-aware styling, the documented v2 pattern requests background color through Tea and reacts to `tea.BackgroundColorMsg`. Keep a fallback style when no reply arrives. Root model methods return a `tea.View`; embedded Bubbles often still render strings. Do not change every component's View signature merely because the root signature changed.

## Choose components for their interaction semantics

**Text input / textarea:** use for editing, cursor movement, focus, and paste behavior. Configure their styles and dimensions with the target version's API. Keep app shortcuts from stealing printable input. Do not replace their editing model with ad hoc rune slicing to save a small amount of code.

**List:** appropriate when its filtering, pagination, selection, and help behavior fit. A custom delegate can preserve a bespoke row design. A simple fixed list may only need a slice and cursor; a huge variable-height transcript may need a specialized view. Do not force all three into one abstraction.

**Table:** appropriate when column comparison is the main task. Decide what columns survive narrowing and what long values do. A table-shaped display is not necessarily an interactive Bubbles table; static Lip Gloss tables serve a different role.

**Viewport:** owns scrolling, not necessarily the expensive work of generating all content. Decide whether to wrap, clip, or scroll horizontally. Regenerating content should preserve the user's anchor unless a deliberate navigation action changes it.

**Help + key:** use a shared vocabulary for routing and hints. Enabled bindings should reflect the active state. A hand-written one-line footer can be sufficient for a truly tiny interaction, but it must not drift from the implementation.

**Spinner / progress / timer:** choose according to available information. Unknown-duration work needs activity, not a fabricated percentage. Preserve returned scheduling commands and stop inactive animation.

These component categories are documented in the Bubbles catalogue; the selection criteria above are recommendations. [S02](sources.md#s02)

**Huh:** useful for forms, field validation, and accessible prompting. It is not a reason to turn an arbitrary browser into a form. Do not start a second blocking interactive loop inside a running Tea update function; follow documented embedding or handoff patterns. [S11](sources.md#s11)

**Gum:** useful for shell-script composition. Importing an entire application because it contains an appealing picker is usually less appropriate than using the underlying Bubbles or learning its interaction pattern. [S07](sources.md#s07)

**Glamour:** use when Markdown formatting is the task, then cache or schedule expensive rendering appropriately. **Wish:** investigate when serving a TUI over SSH, with session-local ownership. These are optional capabilities, not default dependencies. [S17](sources.md#s17)

## Testing dependencies must match too

The inspected legacy `github.com/charmbracelet/x/exp/teatest` module depends on Bubble Tea v1. The separate module `github.com/charmbracelet/x/exp/teatest/v2` exists and imports `charm.land/bubbletea/v2`. Its inspected `go.mod` declares Go 1.24.2 and a v2 release-candidate minimum dependency. These are facts about the inspected files, not proof of compatibility with every later release. Select and test an appropriate revision in the target application's graph. [S12](sources.md#s12) [S13](sources.md#s13)

The v2 helper supports initial terminal size, program options, sending messages, typing text, waiting for conditions, and reading final model/output with timeouts. Read its current implementation before relying on test lifecycle behavior. A virtual-input test is not equivalent to a real terminal restoration test. [S14](sources.md#s14)
