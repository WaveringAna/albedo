# Provider requests

Every provider call the daemon makes leaves one row in `provider_requests`, a durable account of what the transcript cannot say later: what the request cost, which account served it, how it ended, and what its prefix looked like. This is the recording half of cache- and quota-aware compaction; the analysis (a meter estimator and λ) is derived from these rows on demand, so nothing beyond them is stored.

Rows are written by the worker that streams the call, one per upstream attempt (up to 8, doubling from 250 ms, for transport failures, timeouts, an early end, a mid-stream `Overloaded`, and HTTP 502-504, 520-524 and 529 (a plain 500 is not retried); 429s belong to account rotation): a turn retried after a gateway hiccup leaves the failed attempt and the successful one as separate rows. Recording must never fail a turn — a failed row write is logged and swallowed, and the call proceeds.

A timeout says where the request was (`types.Timeout(phase, waited_ms)`): connecting, awaiting headers, awaiting the first event (headers came, no event yet), or streaming. Only the first two get the whole ladder. Once headers arrive, the provider has accepted the request and is generating it and billing for it, and the identical request most likely goes quiet for just as long again (argon thinking silently past the budget did this six times in a row). So a call is retried after such a timeout once (`loop.accepted_timeout_retries`), and then the turn fails with `<model> produced no output for N s after the provider accepted the request; …` (or `stopped streaming for N s` when it had streamed). The row's error reads `Timeout <phase> after <ms> ms`. Rows written before phases were recorded say just `Timeout`.

A completed turn with no visible reply and no tool call (Gemini routes sometimes stop after thinking alone) is not committed. The loop sends the request once more with a nudge appended as a trailing user input (`loop.speechless_nudge`, never stored in the transcript), instead of re-sending it unchanged: oh-my-pi refuses to replay a thought-only stop because it buys another full reasoning pass, and gemini-cli nudges the same way. The first call's row stays `ok` with a null `seq`. If the nudged call is speechless too, it is committed and the turn fails with `<model> ended its turn without a reply or a tool call, even when asked again`.

## What a row holds

- `session`, `seq` — the conversation, and the transcript row the call produced: the first assistant row of the response that turn committed (for a tool-call turn, the row carrying the call itself, not the tool output after it). `seq` is null when the call produced no transcript row: a failed call, or a compaction summary, which writes strategy state instead of the transcript.
- `kind` — `turn` for the model/tool loop, `summarizer` for the compaction summary call, `background` for a call an extension sent on the idle session, such as a [cache-warming](cache-warming.md) ping. A `background` row never attaches a seq: background calls commit nothing.
- `profile`, `provider`, `account`, `model` — the saved profile the request went through, `protocol:endpoint` as it was reached, the non-secret label of the account that served (an account id, email, or short key hash; null when the provider has no account pool), and the model.
- `startedMs`, `finishedMs` — when the attempt ran.
- `outcome`, `status`, `error` — `ok`, or `error` with the HTTP status and a truncated error body, so a 429 is a quota reading.
- token counts as the provider reported them: `inputTokens`, `cachedInputTokens`, `cacheCreationTokens`, `cacheWrite5mTokens`, `cacheWrite1hTokens`, `outputTokens`, `reasoningTokens`. Unreported counts are null, not zero.

Providers report these differently and each adapter fills what it can: Anthropic's `cache_creation.ephemeral_5m_input_tokens` / `ephemeral_1h_input_tokens` become the TTL-split writes; OpenAI's `completion_tokens_details.reasoning_tokens` and the Responses API's `output_tokens_details.reasoning_tokens` become reasoning; Antigravity's `thoughtsTokenCount` is reported as reasoning while output keeps folding thoughts in, as before.

## Usage timing

The session's usage for a turn's call reports the span of the attempt that succeeded as `elapsed_ms`, and its output tokens over that span as `tokens_per_second`. A re-emitted usage keeps its call's span; a compaction estimate made no call, so it has none.

## Cache misses

A turn's usage carries `cache_miss_tokens` when its call read much less from cache than the call before it left cached and nothing explains it. The CLI adds the turn's total to its signoff line (`34k miss`). It is read off two ledger rows (`requests.cache_miss` in `daemon/requests.gleam`, called from `harness/loop.gleam` once the call's row exists):

- the previous call is the latest completed `turn` or `background` row of the session; what it left cached is its cache reads plus what it wrote under its marks, or its whole prompt for a provider that reports no writes;
- the call lost that much minus what it read, and it counts when the loss is at least 8192 tokens and over a twentieth of its prompt. the floor clears the rounding providers do: argon caches in blocks of about 2k, flash loses up to about 6k to rounding at any size, Claude's reads are exact;
- it stays quiet when an explanation exists: another model, head (instructions or tools) or projection (a compaction rewrote the history), a history no longer than before (a rewind), a gap since the previous call at least as long as the cache's first fade step (`cache_fade.whole_for_ms`, so the footer countdown already said so), or a previous call that read nothing from cache;
- a clean miss (prefix unchanged, inside the cache's lifetime) is what reaches the chat; `inputChain` on both rows says whether our own prefix drifted.

The loss is saved with the session's latest usage and, like the rest of it, sent again when a client attaches. A turn's signoff sums its calls' losses once each, keyed by the usage's `observed_at`.

TODO (in code): a per-model floor from each cache's block size.

## Prefix identity

What makes cache analysis possible without storing requests. Each row records:

- `headHash` — SHA-256 of the request head: instructions plus tool schemas. One head, one hash.
- `inputs` — how many projected inputs the request carried.
- `replaced` and `projectionHash` — the projection identity. The loop knows how many original inputs the projection replaced (`original length − shared suffix with the projection`); the row carries that count and a hash of the replacement part that stands in for them.
- `strategy` — the active compaction strategy name, when one prepared the request.
- `cacheMarks` — where the request asked the provider to end a cached prefix, and for how long, in prefix order: `{"through": "tools" | "system" | "input", "index"?, "ttlSeconds"}`, where `index` is the projected input the prefix runs through. Claude requests mark the last tool, system prompt, and last input (unless it is a replayed assistant turn) for one hour. Usage splits cache writes by TTL but not reads; with the marks, a read's TTL follows from which marked prefix it covers. Providers that cache on their own (the OpenAI protocols) get `[]`.

- `inputChain` — a cumulative SHA-256 over the request: the head, then each projected input folded in order. The row keeps the running hash (12 hex digits) after every 16th input and after each of the last four, as comma-separated `position:hash` pairs, so a row costs a few hundred bytes however long the history. A request that continues an earlier one repeats the earlier request's hash at that request's last position (inside a tool loop the follow-up is the earlier request plus two inputs, so the last four positions cover it); the first position where two rows that should agree differ bounds where their prefixes drifted. This is what separates a provider-side cache miss (chains agree, `cachedInputTokens` is null or zero) from our own prefix changing (chains disagree). It hashes our projected inputs, not the provider wire body, so it cannot see a difference that only the provider encoding introduces. Null on rows written before it was recorded.
- `firstByteMs` — the delay to the response headers, null when none came. A timeout with headers and no events was accepted and then silent; one without headers never got an answer.
- `totalTokens`, `responseId`, `modelVersion`, `traceId` — what the response said about itself, when the provider says it (the response id from any provider that streams one; Antigravity also reports `totalTokenCount`, which counts thinking that `thoughtsTokenCount` can leave out, `modelVersion`, and the envelope's `traceId`). A failed attempt's token counts are the last usage its stream metered: Gemini routes report usage on intermediate chunks, so a call cut off midway still says what it cost. Before this, failed rows had null counts.
- `stream` — what the attempt streamed before it ended: `firstEventMs` (delay to the first event, null when nothing arrived), `events`, and the bytes of `thinkingBytes` and `outputBytes` (text and call arguments) the events carried. A call that timed out with `events` 0 said nothing at all; one with thinking bytes was reasoning when the connection was abandoned. Null on rows written before streams were traced.

Within one projection the request is append-only, so equal head hash plus equal projection identity means a warm prefix; a changed projection identity means a rewrite that invalidated the cache. A summarizer call carries its own head hash with `replaced` and `projectionHash` null: its history is exactly what it says.

## Local API

`GET /sessions/{session_id}/context?view=requests` reads paged provider
request records from the store. `after` is a durable request-record ID;
opaque `next` continues the same query. The route requires the daemon token.
These records and the server's quota observations use the same stored facts.
See the [HTTP contract](../docs/http-api-design.md#prepared-context-and-request-records)
for fields and bounds.

## Transport

`openai_api` speaks HTTP/1.1 itself (`albedo_openai_transport.erl`) over a socket the process streaming the call owns: plain TCP for `http`, and for `https` TLS verified against the OTP system CAs with HTTPS hostname matching, SNI for named hosts, and ALPN offering only `http/1.1`. Each packet wakes only that process; no connection process sits between the socket and the reducer. The socket closes when its owner exits, and a host header the caller passes (Bedrock signs its own) replaces the one the transport would add.

An exchange's `timeout_ms` bounds connecting and each wait for data. A provider that sets `first_event_timeout_ms` gives its headers and first SSE event a shared deadline instead, counted from when the request went out; keepalive comments do not move it, and `timeout_ms` bounds the waits after the first event. Only Antigravity sets one: 300 s for both, as oh-my-pi allows Cloud Code Assist, because argon streams no thought parts, so its thinking is a silent socket. Everyone else keeps one per-wait budget (60 s for the OpenAI clients, 120 s for Claude, Bedrock, Vertex). `ALBEDO_PROVIDER_TIMEOUT_MS` holds every budget to at most that many ms, so tests can reach a timeout in seconds.

Connections are kept alive. When an exchange returns `Ok`, its connection goes to `albedo_openai_pool`, one process started on first use, which reads whatever the exchange left unread (a stream ends at its terminal event, often before the chunked terminator; at most 64 KiB within 5 s) and then keeps it idle for the next request to the same scheme, host, and port: up to 60 s, at most 8 per host, newest reused first. A request that arrives while the only connections to its host are still reading that rest waits up to 50 ms for one instead of opening its own. A failed or cancelled exchange closes its socket, so the server stops generating. HTTP/1.0 responses, `connection: close`, and close-delimited bodies are never kept, and an idle connection that closes or sends anything is dropped. A request whose pooled connection fails to send, or closes before any response byte, goes out once more on a new connection; any later failure is a transport failure for the retries above. Reuse saves the TCP and TLS handshakes, about 45 ms per request to `api.openai.com` from a nearby network.

A request's timeout (60 s for model providers) bounds connecting and the wait for the response headers. After them, a stream may stay silent for as long as the server takes: some chat-completions servers, z.ai's among them, send a whole tool call in one chunk once it is generated, so writing a large file is silent for minutes. The client then waits on the connection rather than on data. Its sockets use TCP keepalive that starts probing after the same timeout of silence and closes the socket when four probes a quarter of that apart go unanswered, so a dead server still fails the request, as a closed connection the turn retries; cancelling a turn stops the wait at once.

## decode diagnostics

Claude and Antigravity event and replay decoding preserve JSON error categories or expected types and field paths. Diagnostics omit raw provider values and unexpected JSON bytes or sequences.

## Clock sources

`albedo/clock` distinguishes wall timestamps from monotonic deadlines; shared-helper rules live in [runtime](runtime.md#clocks). Request records, quota reset times, and persisted expiry values use system time. Session, family, deletion, and transport deadlines use monotonic time rather than durable timestamps. Codex model-cache freshness retains its OS-clock source through `os_system_ms`.

SSE framing keeps native binary search (a single-byte search each for LF and CR), sub-binary compaction, and native UTF-8 validation of each completed line; `bit_array.to_string` would walk one codepoint per call. Gleam owns field splitting and uses a line that arrived whole without copying it. The events most of a stream is (Responses text, reasoning, and argument deltas; a chat chunk of text, reasoning text, or tool call fragments; Claude's content block deltas; a Vertex or Cloud Code Assist chunk of text and thought parts) are read with the field readers in `openai_api/fields.gleam` instead of `gleam/dynamic/decode`, which re-validates every string and builds field paths even on success; any other shape falls back to the decoder, which owns error messages. Avoid two-byte `binary:match` patterns and `string:trim` on hot paths: both compile a pattern per call. `gleam run -m manual/stream_benchmark` times framing, reduction, and request encoding offline; `gleam run -m manual/stream_rate_benchmark` streams Responses, Chat Completions, Claude, Vertex, and Cloud Code Assist from `test/manual/mock_openai_server.py` through the real transport and reducers, optionally with tool-call arguments and several streams at once, and reports CPU, reductions, and latency per token.
