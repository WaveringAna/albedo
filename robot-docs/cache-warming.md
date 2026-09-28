# cache warming

an idle session waiting on work that will wake it still owns the most expensive thing it has: a warm prompt cache. the warmer re-sends the session's last request, with only the output budget lowered, just before the provider's cache would expire, so the next real turn reads its context from cache instead of rewriting it.

first case: an orchestrator whose children are still running. it sits idle while its cache decays. warming keeps it, and the same eligibility test is one small function (`warm.wanted` in `src/albedo/daemon/warm.gleam`), so persistent agents can add their own reason later.

## when it warms

a session is eligible while:

- it is idle — no turn, compaction or warm ping in flight. a ping holds the session exactly as a compaction run does, so a submit queues behind it and starts when the ping ends; it is short.
- at least one of its children is running (`bus.is_running`, the same answer `agents.self.children()` gives).
- the last request's cached prefix is worth a round trip: at least `minCachedTokens` (default 1024) cached tokens on the turn it repeats — reads plus writes, so a first write-only turn counts.
- a clock can be beat. with cache marks (Claude), the shortest `ttlSeconds` among them. with none — the OpenAI protocols cache on their own — the cache table's entry: `refresh`/`fixed` policy, its first tier's `seconds`. `evict`/`unknown`, or no entry, means no warming (robot-docs/cache-ttl.md).

warming starts when the turn that will be repeated ends, and again after every ping. a child that starts running while the session is already idle does not wake warming until the session's next turn. any new activity — a submit, a turn, a compaction, a model or profile change — cancels the pending ping through a generation counter; a stale tick is dropped when it arrives.

## what a ping sends

exactly the request the turn actually sent: same instructions, tools, inputs, options, cache marks. it is captured, never rebuilt — a rebuild runs `prepare`, which can compact or call the summarizer and change the prefix. when a turn call succeeds, `loop.call` reports the request, its prefix identity, its usage and timing to the session, which keeps the latest one in memory only. a restart simply stops warming.

the only change is the output budget: `max_output_tokens` 1, or 16 on the Responses protocol, whose minimum is higher.

## the stop rule and its arithmetic

ping at `min(0.9 × ttl, ttl − 10)` seconds after the previous send — from the send's start when the entry's clock is `request` (Anthropic counts lifetime from request start), else from its finish.

each ping costs about `read × cached` input; letting the cache go cold costs one rewrite of about `write × cached` — `write` the matching tier's write multiplier (default 1.0), `read` the entry's read multiplier (default 0.1). so at most `floor(write / read)` consecutive pings per idle stretch, then it stops and lets the cache go cold: ski rental, with the break-even at Claude's 5-minute tier at 1.25 / 0.1 = 12 pings ≈ 54 minutes. a new turn resets the budget.

warming also stops when:

- a ping comes back with no cached input tokens although the turn it repeats read or wrote cache — the TTL model was wrong, and its request row keeps the evidence.
- the kernel was released, or the ping failed or was cancelled.
- settings say `enabled: false`.

## the request kind

every ping is a provider request row of kind `warm`, with the same prefix identity (`headHash`, `inputs`, `replaced`, `projectionHash`) and `cacheMarks` as the turn it repeats, and its own usage. its `cachedInputTokens` says whether the cache was still there, which makes every ping a free TTL measurement for phase 2. a ping never attaches a seq, never commits to the transcript, and never publishes stream events; the agents bus does not flap for it (robot-docs/provider-requests.md).

## settings

`$ALBEDO_HOME/extensions.json` under `"warm"`, re-read each time a ping is scheduled:

```json
{ "warm": { "enabled": true, "minCachedTokens": 1024 } }
```

malformed settings fall back to these defaults. the cache table itself (its layers, refresh, local override) is documented in robot-docs/cache-ttl.md.
