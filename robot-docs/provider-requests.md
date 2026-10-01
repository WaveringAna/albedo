# Provider requests

Every provider call the daemon makes leaves one row in `provider_requests`, a durable account of what the transcript cannot say later: what the request cost, which account served it, how it ended, and what its prefix looked like. This is the recording half of cache- and quota-aware compaction; the analysis (a meter estimator and λ) is derived from these rows on demand, so nothing beyond them is stored.

Rows are written by the worker that streams the call, one per upstream attempt: a turn retried after a gateway hiccup leaves the failed attempt and the successful one as separate rows. Recording must never fail a turn — a failed row write is logged and swallowed, and the call proceeds.

## What a row holds

- `session`, `seq` — the conversation, and the transcript row the call produced: the first assistant row of the response that turn committed (for a tool-call turn, the row carrying the call itself, not the tool output after it). `seq` is null when the call produced no transcript row: a failed call, or a compaction summary, which writes strategy state instead of the transcript.
- `kind` — `turn` for the model/tool loop, `summarizer` for the compaction summary call, `background` for a call an extension sent on the idle session, such as a [cache-warming](cache-warming.md) ping. A `background` row never attaches a seq: background calls commit nothing.
- `profile`, `provider`, `account`, `model` — the saved profile the request went through, `protocol:endpoint` as it was reached, the non-secret label of the account that served (an account id, email, or short key hash; null when the provider has no account pool), and the model.
- `startedMs`, `finishedMs` — when the attempt ran.
- `outcome`, `status`, `error` — `ok`, or `error` with the HTTP status and a truncated error body, so a 429 is a quota reading.
- token counts as the provider reported them: `inputTokens`, `cachedInputTokens`, `cacheCreationTokens`, `cacheWrite5mTokens`, `cacheWrite1hTokens`, `outputTokens`, `reasoningTokens`. Unreported counts are null, not zero.

Providers report these differently and each adapter fills what it can: Anthropic's `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` become the TTL-split writes; OpenAI's `completion_tokens_details.reasoning_tokens` and the Responses API's `output_tokens_details.reasoning_tokens` become reasoning; Antigravity's `thoughtsTokenCount` is reported as reasoning while output keeps folding thoughts in, as before.

## Prefix identity

What makes cache analysis possible without storing requests. Each row records:

- `headHash` — SHA-256 of the request head: instructions plus tool schemas. One head, one hash.
- `inputs` — how many projected inputs the request carried.
- `replaced` and `projectionHash` — the projection identity. The loop knows how many original inputs the projection replaced (`original length − shared suffix with the projection`); the row carries that count and a hash of the replacement part that stands in for them.
- `strategy` — the active compaction strategy name, when one prepared the request.
- `cacheMarks` — where the request asked the provider to end a cached prefix, and for how long, in prefix order: `{"through": "tools" | "system" | "input", "index"?, "ttlSeconds"}`, where `index` is the projected input the prefix runs through. Claude requests mark the last tool and the system prompt for an hour and the last input (unless it is a replayed assistant turn) for Anthropic's default five minutes. Usage splits cache writes by TTL but not reads; with the marks, a read's TTL follows from which marked prefix it covers. Providers that cache on their own (the OpenAI protocols) get `[]`.

Within one projection the request is append-only, so equal head hash plus equal projection identity means a warm prefix; a changed projection identity means a rewrite that invalidated the cache. A summarizer call carries its own head hash with `replaced` and `projectionHash` null: its history is exactly what it says.

## Local API

`GET /sessions/:id/requests` answers rows oldest first, read-only straight from the store:

- `?after=<id>` continues from the last row id of the previous page.
- `?limit=<n>` bounds the page (1–500, default 100).

The response is `{session, rows, after}`; `after` is the id to continue from. Like every session route it needs the daemon token. The later `/quota` inspector reads the same rows; nothing is stored twice.

## decode diagnostics

Claude and Antigravity event and replay decoding preserve JSON error categories or expected types and field paths. Diagnostics omit raw provider values and unexpected JSON bytes or sequences.
