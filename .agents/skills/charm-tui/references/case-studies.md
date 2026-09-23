# Case studies: observation → lesson → limit

The material below comes from selected source files and official documentation, not a claim that the complete applications were executed or audited. Revisions and exact inspection scope are in the [source ledger](sources.md).

## Glow: navigation as an explicit state machine

**Observed.** The root distinguishes file-list and document states, composes listing/pager children, propagates size changes, and routes commands returned by children. An active filter can receive `q` rather than having the root interpret it as quit. Some background messages are deliberately routed to the listing even while the document view is visible. [S05](sources.md#s05)

**Lesson.** Treat “which screen is visible?” and “which component owns this result?” as separate questions. Route keys by interaction context and background results by lifecycle ownership. Keep back navigation and document unloading explicit.

**Limit.** Do not copy every startup, file-reading, or terminal-rendering decision. The source is a real evolving application, not a minimal correctness specification. Its channel loop illustrates re-arming, but a new implementation still needs its own cancellation contract.

## Gum: a small interaction can be a complete product

**Observed.** Filter has distinct cursor and selected-item state, focus-dependent bindings, styled match ranges, and inline/full-screen behavior. Its command wrapper builds components, reads candidate input, renders to stderr, receives the final model, and emits the selected value afterward. [S06](sources.md#s06) [S07](sources.md#s07)

**Lesson.** Shell composability is UX. A narrow picker can be polished without becoming a persistent application shell. Separate canonical values, decorated labels, live UI, and final output. Reuse input and help behavior while keeping a task-specific presentation.

**Limit.** Small-app implementation choices do not automatically scale. The inspected filter renders candidates into viewport content and mutates that viewport during View. Those are observations, not recommendations to render every row or mutate UI state from every View. Test empty-result actions and large candidate sets independently.

## Crush: central coordination without a model for every region

**Observed.** Its UI development notes describe a single root model with targeted helper methods, explicit focus, stacked dialogs, semantic styles, and a hybrid rectangular/string rendering pipeline. The actual list implementation has item caches, width-sensitive invalidation, complete-height caching, bounded overflow detection, and incremental prewarming. [S08](sources.md#s08) [S09](sources.md#s09)

**Lesson.** A sophisticated TUI can centralize event ownership while keeping display helpers simple. Optimize expensive transcript work around visible content and explicit invalidation. Ask “does this overflow?” without always computing an exact full-history height.

**Limit and source conflict.** At the inspected commit, `AGENTS.md` says there is no list-level cache, but `list.go` contains one. The code is the stronger evidence for that implementation detail. Documentation can preserve a useful principle while lagging a refactor. Do not repeat the stale claim or transplant Crush's full subsystem into a twenty-row picker.

## Soft Serve: help and geometry are part of navigation

**Observed.** The SSH root has active-page state distinct from loading/error/ready state. Help is derived from the active page and filter status. Layout accounts for the rendered footer, and error presentation keeps recovery controls available. [S10](sources.md#s10)

**Lesson.** Help belongs to the current interaction and consumes real geometry. A terminal application served remotely also needs an intentional session boundary; do not share mutable screen state or terminal capabilities across users.

**Limit.** This was a selected root-file read, not a security review of the SSH service. Do not infer authentication or concurrency guarantees from a UI example. Avoid copying a whole page framework when a small local tool has only one screen.

## Huh: accessibility can change the interaction model

**Observed.** Huh documents forms, validation, themes, and an accessible mode that uses ordinary prompts instead of its normal TUI presentation. [S11](sources.md#s11)

**Lesson.** Accessibility is not only a different shade of gray. For a bounded data-entry task, a sequential prompt flow can be a valuable first-class interface. Validation should explain what needs fixing and keep the user in control.

**Limit.** A form abstraction is not automatically the right choice for a streaming log, repository browser, or custom picker. The studied Huh material was official documentation, not its full implementation.

## Cross-application synthesis

The recurring quality is not a mandatory color or border. It is a clear task, predictable input ownership, concise feedback, useful defaults, and respect for the terminal and shell around the application. The engineering counterpart is a small number of state owners, effects with lifetimes, cell-correct layout, and evidence from actual interaction tests.

Apply these ideas as judgment, not as a rewrite mandate. Preserve a working product's distinctive interaction and visuals while simplifying duplicated plumbing underneath it.
