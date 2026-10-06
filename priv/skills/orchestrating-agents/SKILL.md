---
name: orchestrating-agents
description: Plan, brief, supervise, and verify parallel subagents working in one checkout. Use when fanning work out to child agents, writing their task briefs, handling their reports, or deciding what to verify yourself before telling the user a fan-out is done.
---

# Orchestrating agents

Children multiply throughput and mistakes equally. You own the plan, the shared machine, and the truth of every report. A child's report is a claim to check, not a result.

## Plan

- Order work by dependency. Build what the rest is judged against first (a harness, an API, a coverage map), verify it, then fan out the work that relies on it.
- A newly spawned child may report `running=False` and have no transcript while
  its kernel is being prepared. Neither proves failure. End your turn and wait
  for mail; do not cancel it solely on those observations.
- Split by disjoint file ownership. Two children share a file only if one of them only reads it. Give shared infrastructure one owner, or allow only small additive edits to it.
- Cap concurrency from the machine, not the task count: three is a sane default for build-heavy work. Pair different toolchains rather than two of the same, since builds contend for the same locks. Queue the rest.
- Choose models deliberately. List what is available (`agents.models()`), pick explicitly, and confirm a model can actually run on this account before relying on it; a child that cannot start costs a whole round. A small, fast model is enough for reading and summarizing. Use a stronger one for judgment, implementation, and review. If a child stalls, asks permission for its core task, or hands in hollow work twice, replace it with a stronger model and the same brief instead of coaching a third attempt.

## Write the brief

Every brief carries:

1. The user's instruction verbatim, with any example they pointed at inlined.
2. The policy to apply. Point at a skill or doc to read first instead of paraphrasing it. Tell the child to read the docs for the subsystem it touches before editing it.
3. Ownership: the files this child owns, and a roster of siblings with the files they own. Siblings can be mailed by name, and a blocker in someone else's file goes to its owner, not to you.
4. The shared contract, if children depend on each other: exact names, fields, and defaults, written once, in every brief.
5. Rules: no commits unless you say so, no branch switching, stash, or reset, and leave anything unexpected alone. Name the heavy commands they must not run.
6. The finish line: which commands must pass, the real output to paste, and an itemised account of what changed. Say that required tests are part of done, that partial replies are for named blockers only, and that "no time" is not a blocker. End with how to report back (`mail.submit("parent", ...)`).

## Supervise

- Check claims against the source, with numbers. Compare test and assertion counts before and after; a port that passes with a quarter of the old assertions lost coverage. Read the diff, not the summary. Build the evidence a claim needs yourself when a child's conclusion drives a decision (for example inventory what is actually stored before accepting "this cannot be removed").
- Run the full suite yourself before relaying "green". Children's final runs miss flakes and ordering effects. Use `git status`, not `git diff --stat`: new files do not appear in a diff.
- A required deliverable that is missing is not done. Send the child back with the exact list. If it misses again, do it yourself rather than a third round.
- Reject symptom fixes: a longer timeout, `expectedFailure`, marking everything exclusive, a "may race" diagnosis. Ask for the mechanism: the code path, the error body, the timing. Many of these are product bugs that deserve a product fix.
- Test that a feature does something, not only that it compiles. A background cleanup that deletes nothing passes every unit test until something exercises it through the real program.
- Make a small change yourself when a child is blocked on code outside its ownership, then tell it exactly what changed.
- Watch for bulk-produced justifications: one reason repeated across a whole file of kept items, or a batch of labels with templated reasons, means nobody looked individually. Spot-check a sample against the source.

## Resources

- Serialise heavy suites behind one lock, and let children run single tests while iterating and the full suite once at the end.
- Keep tests hermetic: point them at a temp directory, never the user's real home or config. A suite that reads the real home fails for reasons that look like another child's breakage.
- Never let a service outlive its runner. Check for leftovers after runs, and close finished children: an open child keeps its processes alive.
- Before blaming the fan-out for load, look at the top processes and measure.

## Shared checkout

- A failure in a file you do not own is assumed to be in-flight work. Route it to the owner and keep your own files compiling.
- Commit only paths you name explicitly, after reading `git status`. Ask before committing or restoring a deletion nobody claims; the user may have moved the file on purpose.
- Be exact about where work goes. When the user says "push" or "merge", confirm the target (a branch, a pull request, or the main branch) if it is not obvious.

## Stay in scope toward the user

- "Show me X" means show it to them, not publish it. Keep a demo page or scratch artifact out of a pull request unless asked.
- Once the user says they are merging, stop changing what they are merging. Offer further edits afterwards.
- Do not accept a child's design without reading it against the project's own rules. The user should not be the first to notice a boundary violation.

## Report

Lead with the outcome and the numbers you verified: tests run, wall time, what remains. Separate what you checked yourself from what a child claims. Put product findings on their own line, and ask before starting a change to product behavior that is larger than the task.
