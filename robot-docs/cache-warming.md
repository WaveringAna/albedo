# cache warming

an idle session waiting on work that will wake it still owns the most expensive thing it has: a warm prompt cache. the `warm` extension re-sends the session's last request, with only the output budget lowered, just before the provider's cache would expire, so the next real turn reads its context from cache instead of rewriting it.

two cases: an orchestrator whose children are still running, and a session waiting on a background job. either sits idle while its cache decays. warming keeps it, and the eligibility test is one small function (`wanted` in `src/albedo/harness/extensions/warm/extension.gleam`), so persistent agents can add their own reason later.

## enabling it

`warm` is enabled by default. a ping spends tokens on the session's account, but only while work that will wake the session is running and the arithmetic below says the pings pay for themselves, so a session with nothing pending never pings. turn it off globally in `/extensions` or with `{"enabled": {"warm": false}}` in `$ALBEDO_HOME/extensions.json`, or for one session in its `/extensions`. disabling it closes that session's warmer, and any pending ping goes with it.

## how it is built

the warmer is an ordinary `ManagedPlugin` (robot-docs/extensions.md): preparing it for a session starts one warmer process, its `observe` forwards the session's events to that process, and its `close` stops it. everything below — the captured call, the timer, the ping budget, the cost model — lives in that process; the daemon only reports events and runs background calls.

- a turn call that succeeds arrives as `CallSent`: the request exactly as sent, its prefix identity, usage, cache marks, profile, endpoint, protocol and timing. the warmer keeps the latest one in memory only, so a daemon restart loses it; see "after a restart" below.
- `TurnEnded` schedules the first ping; `Compacted` drops the captured call, since nothing the next turn sends is warm yet.
- `Stirred` — a submit, a note, a wake, or a change of model, effort, workspace or extensions — raises a generation counter, so a pending tick scheduled under an older one is dropped when it arrives.
- a ping is the session's background call (`extension.Session.call`): exclusive work that holds the session exactly as a compaction run does, so a submit queues behind it and starts when the ping ends; it is short. a background call refused because a run holds the session ends the stretch.
- none of it needs the kernel. the idle sweep releases an idle kernel after `ALBEDO_IDLE_SECONDS` (default 10 minutes) whatever the warmer plans, but the composition the warmer belongs to stays prepared for the next open, so the session keeps reporting its events to it and its pings still go out. the unload sweep, which would stop the session and its warmer with it, leaves a session alone while one of its children works (robot-docs/sessions.md).

## when it warms

a ping goes out while:

- the session is idle — no turn, compaction or other background call in flight.
- work that will wake it is under way (`extension.Session.awaited`): a background job of its own, or an open child that works — one in a turn (`bus.is_running`, the same answer `agents.self.children()` gives), one idle between turns while its kernel runs a job (`runtime.awaiting_jobs`, which asks the runtime, never the child's actor), or one whose own child works, all the way down. a child waiting on its build is the common case: its turn ended with "i'll pick up when it wakes me", the build's end wakes it, and its report then wakes the parent. a job started with `run(..., service=True)` — a dev server, a file watcher — does not count: nothing waits for it to finish, so it would only spend pings. jobs the kernel cannot list, such as a remote one with no summary, do not count either.
- the last request's cached prefix is worth a round trip: at least `minCachedTokens` (default 1024) cached tokens on the turn it repeats — reads plus writes, so a first write-only turn counts.
- a clock can be beat. with cache marks (Claude), the shortest `ttlSeconds` among them. with none — the OpenAI protocols cache on their own — the cache table's entry: `refresh`/`fixed` policy, its first tier's `seconds`. `evict`/`unknown`, or no entry, means no warming (robot-docs/cache-ttl.md).

warming starts when the turn that will be repeated ends, and again after every ping, or when a restarted session restores its call. a child or job that starts running while the session is already idle does not wake warming until the session's next turn.

## what a ping sends

exactly the request the turn actually sent: same instructions, tools, inputs, options, cache marks. it is captured, not rebuilt, except after a restart. the only change is the output budget: `max_output_tokens` 1, or 16 on the Responses protocol, whose minimum is higher.

## after a restart

a restart ends every warmer with the daemon, while the session's jobs, children and provider cache live on. at boot, the daemon starts the idle sessions still waiting: each session whose reattached kernel runs a job that is not a service (`runtime.resume_kernels` hands it to the registry), each parent of a child the restart resumes mid-turn, and the open ancestors of both, which wait on the same work (the registry's `Rewarm` passes itself on to the parent). such a session takes its kernel without starting a turn (`Rewarm`), and `session_last_call` rebuilds its last turn call:

- the call is the session's latest completed `turn` row with a transcript seq; its request carried the transcript rows before that seq.
- that history goes through the session's model projection and `loop.rebuild`, which builds the request the way a turn does — the pinned or current prompt, tools, effort — but projects it with `compaction.project`, under the strategy's saved state, never compacting. building it writes nothing and calls no model.
- it is kept only when the model, profile and provider are the row's, and its prefix identity (head hash, input count, replaced count, projection hash, strategy) is exactly the row's. anything since that changed the request — a compaction, a model switch, a changed tool set — means no warming.

the warmer hears it as `Restored(call, pings)`: the usage is the turn's, the timing that of the latest send of the prefix (the turn, or a ping that repeated it since), and `pings` those pings, which count against this stretch's budget. a warmer that already holds a call ignores it. the first ping is scheduled from that timing like any other, so a restart that outlasted the cache sends nothing; whether work still waits is asked when the ping would go out, since a child the restart resumes may not be running yet when its parent comes back.

a rebuilt request is what the next turn would send, which can differ from what the turn sent where the turn added something the transcript does not keep (a kernel notice on its newest message). it extends the same cached prefix, which is what a ping keeps warm.

## the stop rule and its arithmetic

ping at `min(0.9 × ttl, ttl − 10)` seconds after the previous send — from the send's start when the entry's clock is `request` (Anthropic counts lifetime from request start), else from its finish.

a warm cache bills the next turn about `read × cached` input, a cold one about `write × cached` — `write` the matching tier's write multiplier (default 1.0), `read` the entry's read multiplier (default 0.1) — and each ping costs another `read × cached`. `n` pings pay for themselves while `(n + 1) × read ≤ write`, so at most `floor(write / read) − 1` consecutive pings per idle stretch, then it stops and lets the cache go cold: ski rental, with the break-even at Claude's 5-minute tier at 1.25 / 0.1 − 1 = 11 pings, one every 270 s, keeping the cache for about 54 minutes. a write priced under twice the read means no warming. a new turn resets the budget.

a tick that fires late (a sleeping machine, a blocked scheduler) past half the margin left before expiry sends nothing: the cache is probably gone, and a ping would pay for a rewrite.

warming also stops when:

- a ping comes back with no cached input tokens although the turn it repeats read or wrote cache — the TTL model was wrong, and its request row keeps the evidence.
- the ping failed, was cancelled, or was refused.
- the extension is disabled.

## the request kind

every ping is a provider request row of kind `background`, with the prefix identity (`headHash`, `inputs`, `replaced`, `projectionHash`) and `cacheMarks` of the turn it repeats, and its own usage. its `cachedInputTokens` says whether the cache was still there, which makes every ping a TTL measurement for cache-policy reports. a background call never attaches a seq, never commits to the transcript, and never publishes stream events; the agents bus does not flap for it (robot-docs/provider-requests.md).

## settings

`$ALBEDO_HOME/extensions.json` under `"warm"`, re-read each time a ping is scheduled:

```json
{ "warm": { "minCachedTokens": 1024 } }
```

when unset or malformed, `minCachedTokens` is 1024. the cache table itself (its layers, refresh, local override) is documented in robot-docs/cache-ttl.md.
