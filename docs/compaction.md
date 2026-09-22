# compaction

Compaction changes only what a request shows the model. The durable transcript, `/tree`, and forks always keep the full conversation.

At most one enabled compaction strategy owns the request view of history. `rolling` is the built-in strategy and is enabled by default.

## rolling

`rolling` projects history as four parts, in order:

1. the system prompt and enabled extension context, which are never compacted
2. one incremental summary of the older conversation it has already evicted
3. a short recap built from recent user messages, quoted verbatim and bounded
4. the newest conversation tail, unchanged

It compacts when the estimated request reaches `triggerPercent` of the configured context window, so roughly the last 10% stays free for work. The tail keeps about `tailPercent` of the window. A cut is only made between whole conversation units, so an assistant tool call always keeps its result.

Each time it compacts, the model folds the previous summary together with the newly evicted history into a replacement summary. That summarizer call carries no tools. Summary and cut position are stored per session and written only after a successful summary, so a provider failure leaves the previous usable projection and the transcript untouched. A branch starts with no projection state, and a provider or model change resets it.

## configure

```json
{ "rolling": { "contextWindowTokens": 200000, "triggerPercent": 90, "tailPercent": 25 } }
```

Put this in `$ALBEDO_HOME/extensions.json`. `contextWindowTokens` is optional: without it, `rolling` asks the enabled [models catalog](models.md) for the current model's context window. An explicit setting always wins. When neither knows the model, `rolling` stays a no-op and `/context` reports the window as unknown rather than inventing one.

Estimates are local byte-based approximations, never provider token accounting. Image payloads are sized by their dimensions, not by base64 length, so an attached image cannot fake a million-token conversation.

Image bytes are never copied into the recap or the summarizer prompt; a recent image stays unchanged while its unit is in the tail.

## inspect

`/context` shows the prepared request: its sections in order, their sources, the compaction status, and what the estimate is based on. See [the context inspector](context.md).
