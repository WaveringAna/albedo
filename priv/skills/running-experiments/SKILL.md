---
name: running-experiments
description: Plan, run, and interpret measured experiments with reproducible source and evidence. Use when testing a hypothesis, comparing implementations or configurations, running an ablation or benchmark, or iterating toward a measured goal. Not for ordinary implementation and regression testing, or literature-only research.
---

# Running experiments

An experiment asks a question; a run is one attempt to answer it. Keep those identities separate: fixing a dependency can require another run without creating another hypothesis. Use the project's existing tools, version control, and notes. No experiment service or parallel agents are required.

## Set the contract

Before launching, write a short plan in project notes or a work item:

- The question, baseline, proposed change, and what result would count against the hypothesis.
- The evaluator: metric, evaluation code revision, input data or split, and conditions that must stay comparable. Separate exploratory data from confirmation data where selection could overfit.
- The decision rule: what improvement matters, what correctness constraints must hold, and how to distinguish an effect from noise. Choose repetitions, seeds, paired inputs, or held-out confirmation before inspecting results.
- The authorized compute, time or cost budget, concurrency, and stopping conditions. Include a repair budget for runs that answer nothing. Use the user's limits; ask when missing limits would authorize material spending or prolonged work.

Inspect and run the baseline before attributing a difference to a variant. If the evaluator or data must be repaired, record the change and rerun affected comparisons under the new contract. Never quietly change the scoring rule to make a variant win.

## Preserve what ran

Use a committed revision or another immutable source snapshot. A branch name or a jj change id can move; record the exact commit id. Before launch, verify that the executed files match it: inspect Git dirty/untracked files, or snapshot the jj working copy before reading its commit id. Record generated or ignored inputs separately. A separate worktree/workspace isolates edits but does not freeze files beneath a running process. Run from a snapshot, or leave its source untouched until the run finishes.

For Git, keep repairs on the same experiment branch with new commits; start a new branch for a new hypothesis. For jj, repairs may stay in the same change, but after an answering run use `jj new <base-commit-id>` before editing the next variant. Choose that base deliberately: the measured variant for a follow-up, or the shared baseline for a sibling comparison. Archive each measured source snapshot or keep its revision reachable without rewriting it; a bookmark that moves with an amended jj change does not preserve the old revision. Neither a commit nor a change is a run id: repetitions of identical code still need separate run records.

Keep one small record per run, linked from its experiment notes:

```text
experiment: question, baseline, intended difference
run: unique id, source commit/snapshot, evaluator revision
execution: exact command, relevant environment/config, dependency versions,
           data version/split, seed, machine and resource limits
evidence: durable log and artifact paths, exit status, measurements
decision: answered / inconclusive / execution failure; next action and why
```

Record relevant environment values, not secrets. Preserve earlier attempts rather than replacing their records with the latest result. Save logs and outputs needed for reproduction before temporary job output expires; `job.save(path)` preserves captured bytes without loading the whole log. Use an ignored or out-of-tree artifact directory unless the project versions experiment artifacts. The work ledger can track the plan and link to evidence; it is not a substitute for the evidence itself.

Comparability matters more than command spelling: different recorded arguments can legitimately express the variable under test. What must not change unnoticed is the evaluation contract. Use versioned configuration when it makes differences easier to inspect.

## Run and interpret

1. Implement the planned change on an isolated branch/workspace when necessary. For each variant, name what its baseline established and what this run changes. Branch from a prior winner only when the new question builds on it; independent comparisons can remain siblings. Do not manufacture a particular tree shape.
2. Launch within the budget. In albedo, bind a `run()` job handle, set `timeout=` to the run budget, and use `cwd=` for the intended source directory; use `remote.connect()` for a remote execution host. Use existing project launchers for schedulers or hosted compute. Verify the source revision and clean state on the execution host, or transfer the recorded snapshot. Record the actual execution target, not just the editing workspace.
3. Await completion or let the job wake the session. Process each independent completion as it arrives; a comparison requiring several runs must wait for that evidence before choosing a winner. For parallel agents, load `orchestrating-agents` and give each helper explicit file ownership and compute limits.
4. Read the logs, verify the effective configuration, and check that the intended evaluation actually ran. A successful exit is not a measurement, and a failed exit does not necessarily erase evidence produced before it.
5. Decide what the run established:
   - **Execution failure:** it did not answer the question. Diagnose and repair the implementation or environment, then record a new run of the same experiment. A dependency fix is not a new scientific hypothesis.
   - **Valid negative result:** the hypothesis was tested and disappointed. Preserve that evidence; changing the hypothesis creates a new variant, not a repair of the old answer.
   - **Inconclusive:** preserve the observations and say what evidence is missing. Repeat or refine the experiment only within the agreed budget.
   - **Apparent improvement:** confirm it under the planned decision rule before making it the next baseline.
6. Continue the next authorized action, or stop at the goal, budget, user interruption, or a blocker needing a decision. Do not end a turn merely announcing an executable next step: do it now, leave a live job or an explicit scheduled prompt that will wake you, or explicitly say that you are stopping or blocked and why. Ending a turn does not schedule another experiment. If repairs keep answering nothing, use the repair limit to stop and explain the blocker rather than relaunching indefinitely.

The distinction depends on the question. An out-of-memory failure can be a setup problem for one experiment and the answer to “does this fit within 8 GiB?” for another. If the evidence cannot distinguish an implementation defect from a genuine negative result, preserve it as inconclusive rather than explaining it away.

## Two examples

**Correctness:** “Does this parser preserve the reference parser's output on the fixed corpus?” Pin the corpus and comparator. A missing dependency is an execution failure; a reproducible output mismatch is evidence against equivalence. Preserve the mismatch and both revisions. Fixing the candidate after that finding creates a new variant to evaluate, not a retroactive pass for the old one.

**Performance:** “Does this index reduce lookup latency without changing answers?” First verify answer equivalence. Compare baseline and candidate on the same machine and inputs, control warm-up, and interleave repeated measurements to reduce drift. Keep competing workloads off that machine and use the same process priority for both variants (`run()` starts jobs at low priority). Pick a meaningful effect threshold and confirmation workload before selecting a winner; a single faster run is a lead, not confirmation.

## Report

State the question, what actually ran, the measured result and its uncertainty, the decision, and the next action or stop reason. Link the run records and supporting logs. Distinguish “no improvement established” from “equivalent,” and a validated outcome from a run that merely completed.
