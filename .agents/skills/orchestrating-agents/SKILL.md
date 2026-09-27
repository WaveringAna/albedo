---
name: orchestrating-agents
description: Plan, brief, supervise, and verify parallel subagents working in one checkout. Use when fanning work out to child agents, writing their task briefs, handling their reports, or deciding what to verify yourself before telling the user a fan-out is done.
---

# Orchestrating agents

Children multiply throughput and mistakes equally. The parent owns the plan, the shared machine, and the truth of every report. Treat child reports as claims to check, not results.

## Plan the phases

- Order work by dependency, not by eagerness. Build whatever the rest is judged against first (a harness, a coverage map, an API), verify it, and only then fan out the work that relies on it.
- Split by disjoint file ownership. Two children may share a file only when one of them only reads it. Name one owner for shared infrastructure, or allow only additive edits to it, made with targeted edits and never whole-file rewrites.
- Decide the concurrency cap from the machine, not the task count (see Resources). Queue the rest and start each one as a slot frees up.

## Write the brief

Every brief carries:

1. The user's instruction verbatim, plus any example they pointed at, inlined.
2. The policy to apply. Point at a skill (for example `writing-tests`) instead of paraphrasing it.
3. Ownership: the files this child owns, and a **roster of siblings with the files they own**. Say that siblings can be mailed directly by name (`mail.submit("<name>", …)`), and that a blocker in someone else's file goes to its owner, not to the parent.
4. Resource rules (below) and repo rules: no commits, no branch switching, no stash or reset, and leave paths the user moved alone.
5. The finish line and its evidence: which commands must pass, the real output to paste, and an itemised account (for example every old assertion mapped to its new home, or every kept test with a one-line reason). Say that partial replies are only for real blockers, and that the blocker must be named.

## Supervise

- **Check claims with numbers.** Compare assertion counts, test counts, and line counts before and after. A port that "passes" with a quarter of the old assertions has lost coverage.
- **Run the suite yourself** before relaying "green". Children's final runs miss flakes and ordering effects.
- **Reject symptom fixes**: a longer timeout, `expectedFailure`, marking everything exclusive, a "may race" diagnosis. Ask for the mechanism: the code path, the error body, the timing. Several of these turned out to be real product bugs (a stream that stayed silent for 5s, mail that waited for a 15s tick) and deserved a fix in the product, not in the test.
- **Make the product change yourself** when a child is blocked on code outside its ownership and the change is small. Then tell the child exactly what changed and what to do next.
- **Replace a weak model early.** When a child stalls, asks permission for its core task, or hands in hollow work twice, respawn it on a stronger model with the same brief. Don't coach it through a third attempt.
- **Don't be fooled by bulk-produced justifications.** When one "reason" is repeated across a whole file of kept items, look closer in review.

## Resources

The machine is usually the user's laptop, and every child's builds and tests land on it.

- Cap concurrent children (three is a sane default for build-heavy work) and pair different toolchains (Go with Gleam) rather than two of the same.
- Serialise heavy suites behind a machine-wide lock (`fcntl.flock` in the runner). Children run single tests while iterating and the full suite once at the end.
- One long-lived service per test run, not one per test. Shrink it for tests (for example `ERL_FLAGS="+S 2:2 +sbwt none"`), and restart it in place only when a restart is the thing under test.
- Never let a service outlive its runner. Tie it to the runner's pid and refuse to start it from an agent kernel or REPL, which never exits. Check `ps` after runs and kill leftovers that belong to the test.
- Before blaming the fan-out for load, look at the top processes. OS bugs happen (a macOS `dasd` scheduling loop once pinned a core). Measure before you throttle.
- Close children when they finish: an open child keeps its kernel, and anything that kernel started, alive.

## Shared checkout hygiene

- Keep tests hermetic. A suite that reads the user's real home or config (`~/.albedo`) fails for reasons that look like another child's breakage. Point it at a temp directory.
- A failure in a file you don't own is assumed to be in-flight work. Route it to the owner, and keep your own files compiling.
- Commit only paths you name explicitly (`git add -- <paths>`), on a branch, after reading `git status`. Ask about deletions nobody claims before you commit or restore them; the user may have moved the files on purpose.

## Report to the user

Lead with the outcome and the numbers you verified: tests, wall time, lines removed, what's left. Separate what you checked yourself from what a child claims. Flag product findings on their own line, and ask before starting a change to product behaviour that's larger than the task.
