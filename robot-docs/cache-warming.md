# cache warming

an idle session waiting on work that will wake it still owns the most expensive thing it has: a warm prompt cache. the `warm` extension re-sends the session's last request, with only the output budget lowered, just before the provider's cache would expire, so the next real turn reads its context from cache instead of rewriting it.

first case: an orchestrator whose children are still running. it sits idle while its cache decays. warming keeps it, and the same eligibility test is one small function (`wanted` in `src/albedo/harness/extensions/warm/extension.gleam`), so persistent agents can add their own reason later.

## enabling it

`warm` is installed and disabled: a ping spends tokens on the session's account. enable it globally in `/extensions` or with `{"enabled": {"warm": true}}` in `$ALBEDO_HOME/extensions.json`, or for one session in its `/extensions`. disabling it closes that session's warmer, and any pending ping goes with it.

## how it is built

the warmer is an ordinary `ManagedPlugin` (robot-docs/extensions.md): preparing it for a session starts one warmer process, its `observe` forwards the session's events to that process, and its `close` stops it. everything below — the captured call, the timer, the ping budget, the cost model — lives in that process; the daemon only reports events and runs background calls.

- a turn call that succeeds arrives as `CallSent`: the request exactly as sent, its prefix identity, usage, cache marks, profile, endpoint, protocol and timing. the warmer keeps the latest one in memory only; a restart simply stops warming.
- `TurnEnded` schedules the first ping; `Compacted` drops the captured call, since nothing the next turn sends is warm yet.
- `Stirred` — a submit, a note, a wake, or a change of model, effort, workspace or extensions — raises a generation counter, so a pending tick scheduled under an older one is dropped when it arrives.
- a ping is the session's background call (`extension.Session.call`): exclusive work that holds the session exactly as a compaction run does, so a submit queues behind it and starts when the ping ends; it is short. a background call refused because a run holds the session, or because the kernel was released, ends the stretch.

## when it warms

a ping goes out while:

- the session is idle — no turn, compaction or other background call in flight.
- at least one of its children is running (`bus.is_running`, the same answer `agents.self.children()` gives).
- the last request's cached prefix is worth a round trip: at least `minCachedTokens` (default 1024) cached tokens on the turn it repeats — reads plus writes, so a first write-only turn counts.
- a clock can be beat. with cache marks (Claude), the shortest `ttlSeconds` among them. with none — the OpenAI protocols cache on their own — the cache table's entry: `refresh`/`fixed` policy, its first tier's `seconds`. `evict`/`unknown`, or no entry, means no warming (robot-docs/cache-ttl.md).

warming starts when the turn that will be repeated ends, and again after every ping. a child that starts running while the session is already idle does not wake warming until the session's next turn.

## what a ping sends

exactly the request the turn actually sent: same instructions, tools, inputs, options, cache marks. it is captured, never rebuilt — a rebuild runs `prepare`, which can compact or call the summarizer and change the prefix. the only change is the output budget: `max_output_tokens` 1, or 16 on the Responses protocol, whose minimum is higher.

## the stop rule and its arithmetic

ping at `min(0.9 × ttl, ttl − 10)` seconds after the previous send — from the send's start when the entry's clock is `request` (Anthropic counts lifetime from request start), else from its finish.

each ping costs about `read × cached` input; letting the cache go cold costs one rewrite of about `write × cached` — `write` the matching tier's write multiplier (default 1.0), `read` the entry's read multiplier (default 0.1). so at most `floor(write / read)` consecutive pings per idle stretch, then it stops and lets the cache go cold: ski rental, with the break-even at Claude's 5-minute tier at 1.25 / 0.1 = 12 pings ≈ 54 minutes. a new turn resets the budget.

warming also stops when:

- a ping comes back with no cached input tokens although the turn it repeats read or wrote cache — the TTL model was wrong, and its request row keeps the evidence.
- the ping failed, was cancelled, or was refused.
- the extension is disabled.

## the request kind

every ping is a provider request row of kind `background`, with the prefix identity (`headHash`, `inputs`, `replaced`, `projectionHash`) and `cacheMarks` of the turn it repeats, and its own usage. its `cachedInputTokens` says whether the cache was still there, which makes every ping a free TTL measurement for phase 2. a background call never attaches a seq, never commits to the transcript, and never publishes stream events; the agents bus does not flap for it (robot-docs/provider-requests.md).

## settings

`$ALBEDO_HOME/extensions.json` under `"warm"`, re-read each time a ping is scheduled:

```json
{ "warm": { "minCachedTokens": 1024 } }
```

when unset or malformed, `minCachedTokens` is 1024. the cache table itself (its layers, refresh, local override) is documented in robot-docs/cache-ttl.md.
