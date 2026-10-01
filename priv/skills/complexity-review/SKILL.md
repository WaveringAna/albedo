---
name: complexity-review
description: Review a change for time and space complexity and for unbounded growth. Use when the user asks whether a diff is efficient, what an operation's complexity is, why something is slow or large, or to speed up or shrink something that scales with history, file size, session length, or stored data.
---

# Complexity review

State the cost of what changed, in terms of the sizes that actually grow, and fix only what scales badly on a path that matters. A cold path that is O(n) once is fine; an O(n) rebuild on every click is not.

## Find the sizes and the frequency

For each new or changed operation, write down:

- **What grows**: history length, rows rendered, file or payload size, session count, stored bytes. Use the real quantity, not "n".
- **How often it runs**: per token, per keystroke or click, per turn, per request, per startup, per day. Frequency decides whether a cost matters.
- **Where it runs**: on the request or render path, or in the background. Work off the hot path can afford more.

Then state time and space per operation. Say worst case and typical case when they differ, and say when an amortized claim holds.

## What to look for

- **Whole-collection work for a local change**: rebuilding or rescanning all history to change one item. Prefer rendering only the affected item and splicing it in; keep a fallback rebuild for when the splice cannot be trusted.
- **Repeated scans**: a regex or search over every row each time, a lookup in a list inside a loop (quadratic), N+1 queries, sorting inside a loop, string concatenation in a loop.
- **Placement**: per-turn work that only needs to happen when something changes (for example on commit or on compaction, not every turn), and work that can be cached by a key that includes everything it depends on.
- **Space**: what is retained and for how long. Look for unbounded caches, buffers that grow with a stream, whole-file reads where streaming works, duplicated copies of large payloads, and per-session state with no cap.
- **Persisted growth**: anything written per session or per event needs a cap, and a way to expire or reap it. Say what removes it and when.
- **Hidden costs of correctness**: validation or copying that scales with payload size on every call.

## Prove it

Do not rely on reading alone for a claim that matters.

- Measure at two sizes (for example 1x and 10x) and check the cost scales the way you said. Report numbers.
- When you replace a full recompute with an incremental update, add a test that the incremental result equals the full one, after each kind of change.
- When you claim a bound (O(1) memory, at most N bytes), add a test that fails if it is exceeded.
- Check the failure path too: what happens at the cap, on an error halfway, with empty input.

## Report

```text
Operation   Cost (time / space)   Runs        Verdict
<what>      <in real sizes>       <frequency> <fine | fix: smallest change>
```

Lead with the operations that scale badly on a hot path. For each, give the smallest fix that removes the growth, and say what you left alone because it is cold or small. Do not add complexity to the code to save cost that no path pays.
