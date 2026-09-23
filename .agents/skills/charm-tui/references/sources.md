# Source ledger

Research date: **2026-09-23**. Primary sources only. Application revisions below are the commit-pinned URLs returned during inspection. A GitHub file's content SHA is not interchangeable with a repository commit; only repository revisions are used in these permalinks.

This is an independent synthesis. Observed implementation details, documented APIs, and recommended practices are distinguished in the other references. No upstream application was built, executed, or exhaustively audited during this research. Public documentation may change; inspect the target repository's pinned dependencies before using version-sensitive advice.

## S01

**Bubble Tea: current API, upgrade guide, and release.**

- [API inspected at v2.0.9](https://pkg.go.dev/charm.land/bubbletea/v2@v2.0.9)
- [v2 upgrade guide](https://github.com/charmbracelet/bubbletea/blob/main/UPGRADE_GUIDE_V2.md)
- [v2.0.9 release](https://github.com/charmbracelet/bubbletea/releases/tag/v2.0.9), published 2026-08-19
- [README and tutorial](https://github.com/charmbracelet/bubbletea)

Read for model/command/view APIs, input migration, view configuration, and command ordering. The release API independently confirmed the v2.0.9 tag. The upgrade guide was a default-branch snapshot, not pinned to the application's version.

## S02

**Bubbles: catalogue and v2 migration.**

- [API inspected at v2.2.1](https://pkg.go.dev/charm.land/bubbles/v2@v2.2.1)
- [v2 upgrade guide](https://github.com/charmbracelet/bubbles/blob/main/UPGRADE_GUIDE_V2.md)
- [Component catalogue](https://github.com/charmbracelet/bubbles)

Read the catalogue, guide introduction and global patterns through the beginning of progress migration. Verified selected concrete v2 input/viewport usage against Gum's source. The displayed documentation publication date was 2026-08-24. Do not treat the abridged comparison table as an exhaustive migration guide.

## S03

**Lip Gloss: layout and v2 style/color model.**

- [API inspected at v2.0.6](https://pkg.go.dev/charm.land/lipgloss/v2@v2.0.6)
- [Width contract](https://pkg.go.dev/charm.land/lipgloss/v2@v2.0.6#Style.Width)
- [Frame helper](https://pkg.go.dev/charm.land/lipgloss/v2@v2.0.6#Style.GetHorizontalFrameSize)
- [v2 upgrade guide](https://github.com/charmbracelet/lipgloss/blob/main/UPGRADE_GUIDE_V2.md)

Read layout/color documentation and upgrade material. The displayed documentation publication date was 2026-08-11. Width includes internal border/padding and excludes margins; color handling moved toward output-layer adaptation. This is the source for the skill's version-specific arithmetic, not a CSS analogy.

## S04

**Charm: Commands in Bubble Tea.**

- [Official engineering article](https://charm.land/blog/commands-in-bubbletea/)

Read for the purpose of commands, side effects, and avoiding command-based internal message routing. Treat older snippets as conceptual material and translate only after verifying the target APIs. The skill's cancellation and generation protocol is a derived recommendation, not a quotation of this article.

## S05

**Glow root UI.** Revision `6b365eea95f7541d4af441d971010b09f6082a0e`.

- [ui/ui.go](https://github.com/charmbracelet/glow/blob/6b365eea95f7541d4af441d971010b09f6082a0e/ui/ui.go)

Read lines 1–465 (the root file): state transitions, key routing, child delegation, theme and size events, view modes, file-discovery commands. The pager/stash internals and specialized renderer were not exhaustively read.

## S06

**Gum filter interaction and rendering.** Revision `7179388031ae67d7f538d001be87d931f1cf5e28`.

- [filter/filter.go](https://github.com/charmbracelet/gum/blob/7179388031ae67d7f538d001be87d931f1cf5e28/filter/filter.go)

Read lines 1–270 and 280–525: keys, state, help, rendering, resize, filtering, cursor/selection behavior, and match-position handling. A small intervening portion and the remainder were not needed for the extracted lessons; this was not a complete file audit.

## S07

**Gum command boundary.** Same revision as S06.

- [filter/command.go](https://github.com/charmbracelet/gum/blob/7179388031ae67d7f538d001be87d931f1cf5e28/filter/command.go)

Read the command wrapper: component construction, stdin candidates, stderr UI, context ownership, final-model outcome, and result output. This supports shell-composition lessons, not a guarantee of every Gum subcommand's semantics.

## S08

**Crush maintainer UI instructions.** Revision `72654940d9e46961a7d804d536c45761e7084a08`.

- [internal/ui/AGENTS.md](https://github.com/charmbracelet/crush/blob/72654940d9e46961a7d804d536c45761e7084a08/internal/ui/AGENTS.md)

Read the architecture, component, dialog, style, and performance guidance. These are maintainer notes, not runtime evidence. The “no list-level cache” statement conflicts with S09 at the same revision; the skill follows the source for that detail.

## S09

**Crush list implementation.** Same revision as S08.

- [internal/ui/list/list.go](https://github.com/charmbracelet/crush/blob/72654940d9e46961a7d804d536c45761e7084a08/internal/ui/list/list.go)

Read lines 1–220: fields and cache entries, construction, width-change invalidation, bounded bottom checks, full-height caching, prewarming, and beginning of the overflow method. The whole render/invalidation subsystem was not audited. The initial source segment suffices to establish the cache's existence and stated width dependency.

## S10

**Soft Serve SSH root UI.** Revision `37685d36f5b7bf0e32217ddd7c8e045c57772619`.

- [pkg/ssh/ui.go](https://github.com/charmbracelet/soft-serve/blob/37685d36f5b7bf0e32217ddd7c8e045c57772619/pkg/ssh/ui.go)

Read lines 1–300: page/session state, contextual help, sizing, update routing, and view assembly. The server's authentication and transport implementation were not reviewed.

## S11

**Huh official documentation.**

- [README](https://github.com/charmbracelet/huh)
- [Accessibility section](https://github.com/charmbracelet/huh#accessibility)

Read form, validation/theme, and accessible-mode documentation. This is documentation-level study, not a Huh source audit.

## S12

**Legacy teatest dependency boundary.**

- [exp/teatest/go.mod](https://github.com/charmbracelet/x/blob/main/exp/teatest/go.mod)

Default-branch file inspected during research. It declared Go 1.24.0 and `github.com/charmbracelet/bubbletea v1.3.5`. This is why the unversioned teatest import is not the intended v2 helper.

## S13

**teatest v2 module.**

- [exp/teatest/v2/go.mod](https://github.com/charmbracelet/x/blob/main/exp/teatest/v2/go.mod)

Default-branch file inspected during research. It declared module `github.com/charmbracelet/x/exp/teatest/v2`, Go 1.24.2, and a dependency on `charm.land/bubbletea/v2 v2.0.0-rc.1`. Verify compatibility in the target graph; an existing module is not a promise that an arbitrary revision will fit every application.

## S14

**teatest v2 implementation.**

- [exp/teatest/v2/teatest.go](https://github.com/charmbracelet/x/blob/main/exp/teatest/v2/teatest.go)

Read lines 1–300: options, test program construction, waits, final model/output, sending/typing, quit, and golden-output helper. Use bounded waits and explicit lifecycle handling. This file was source-reviewed, not compiled in the research environment.

## S15

**VHS official command reference and testing notes.**

- [README](https://github.com/charmbracelet/vhs)

Read command reference entries for waits, input, screenshots, environment/recording setup, and text/ASCII outputs used in regression workflows. No recording was produced for this skill.

## S16

**ANSI display-width helpers.**

- [github.com/charmbracelet/x/ansi documentation](https://pkg.go.dev/github.com/charmbracelet/x/ansi)

Read helper catalogue and display-aware string operations. The distinction between ANSI-preserving manipulation and an untrusted-data sanitization policy is an engineering recommendation; this skill does not certify a particular sanitizer.

## S17

**Charm ecosystem overview.**

- [Charm](https://charm.land/)

Read to identify the roles of the core libraries and adjacent tools including Glamour and Wish. Mentioned for selection and scope; their full APIs and implementations were not independently studied here.

## How to refresh this research

Inspect the target repository first. For a new API claim, read official documentation or code at its pinned version. For an application pattern, record a commit permalink and the relevant methods; do not infer the full architecture from a screenshot. When docs disagree with code, report the discrepancy and prefer the implementation for implementation facts. Validate important behavior with tests or an actual terminal run, and record exactly which occurred.


## S17

**APIs checked while adding worked examples, 2026-09-23.**

- [Bubble Tea v2.0.9](https://pkg.go.dev/charm.land/bubbletea/v2@v2.0.9): typed key messages, `tea.View`, command constructors, output/input and context options.
- [Bubbles text input v2.2.1](https://pkg.go.dev/charm.land/bubbles/v2@v2.2.1/textinput): `SetWidth`, `Focus`, `Update`, virtual cursor, styles.
- [Lip Gloss v2.0.6](https://pkg.go.dev/charm.land/lipgloss/v2@v2.0.6): total block width before margins, border/padding sizing, rendering and measurement.
- [ANSI v0.11.8](https://pkg.go.dev/github.com/charmbracelet/x/ansi@v0.11.8): display-cell width and truncation.
- [Terminal v0.2.2](https://pkg.go.dev/github.com/charmbracelet/x/term@v0.2.2): `IsTerminal(fd uintptr)`.

The docs displayed these versions during inspection. The example module uses explicit direct dependency versions, not an assertion that every package is the newest available. API review is not module compilation; transitive resolution and `go.sum` generation were unavailable. The request, retention, output, and sanitization policies in the examples are original application choices, not promises made by Charm.
