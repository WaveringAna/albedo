# compaction

Compaction changes only what a request shows the model. The durable transcript, `/tree`, and forks always keep the full conversation.

The default session uses `rolling`. Selecting another strategy (`snapcompact` or `lcm`) through `/extensions` disables the current one in the same reload. A strategy enabled by name, for a session or globally, displaces a default one it did not choose, so a new default strategy cannot break an older choice. A session with the built-in extensions keeps one compaction strategy enabled. The registry also permits a custom host with no compaction strategy installed.

`/compact` compacts now with the session's strategy. `/compact <strategy>` first makes the named strategy the session's own, as `/extensions` would, then compacts with it. Later requests read the projection that strategy saved. For example, `/compact rolling` before switching to a model without image input leaves a text summary that the new model can read.

A strategy returns prepared inputs and an observation for `/context`. The observation describes that preparation. The inspector does not read strategy state. The durable transcript supplies the source rows for each derived view.

## source references

`conversation.load_sources` reads transcript rows with `SourceRef(session, seq)`. `conversation.source` resolves one reference. The sequence is SQLite's append-only transcript identity. A fork copies rows into a new session with new references. LCM copies saved nodes whose entire source range precedes the fork checkpoint and remaps their row and node IDs without a model call. LCM omits a node that crosses the checkpoint, but can reuse its complete child nodes. The branch may summarize the remaining rows if it later reaches the compaction trigger.

Provider projection can combine several durable rows into one model input, split one row into several inputs, or omit a nonportable reasoning item. `projection.for_model_with_sources` records the rows that produced each projected input. `projection.for_model` still returns plain inputs for existing callers. Synthetic extension context and strategy summaries have no transcript reference.

`lcm` uses durable source rows for summary ranges and plain model inputs for its verbatim tail. It preserves every unsummarized user unit and the latest whole user/tool unit. Source references on live projected inputs would let future strategies cut history within those unit boundaries.

Live source references need the sequence IDs from the transaction that commits inputs. The session coordinator can then project those identified entries before preparing a request. Its current commit callback returns only a timestamp, and its in-memory entries have no sequence field. Callers that do not need references can keep the plain-input path. Text or list positions cannot identify rows reliably because messages can repeat and provider projection can change item counts. An excursion marker belongs to its parent session. The branch has different row references, so returning its outcome requires an explicit link to the parent marker.

## stored folds

A strategy reads folds another strategy stored through `context.prior(history)`, never by importing that strategy. It returns `Prior(folds, rest)`: the stored summaries, oldest first, and the history they do not cover. Without stored folds, `folds` is empty and `rest` is the history unchanged. The extension that owns the storage registers a `FoldPlugin`; the runtime applies every enabled provider in registry order, except a provider owned by the active strategy, which reads its own state. `lcm-memory` provides LCM's folds and `snapcompact-memory` the snapcompact archive, so each stays visible after a switch away. `lcm-memory` comes first, so the archive covers history past LCM's folds. `lcm` ignores `prior`.

## lcm

`lcm` implements the source-backed memory part of [Lossless Context Management](https://arxiv.org/html/2605.04050v1). It stores leaf summaries, condensed parent summaries, child links, and a covered source cursor in SQLite. The durable transcript supplies their source rows. The summary tree belongs to one session. A fork copies complete prefix summaries and their links with remapped row and node IDs.

Before the configured trigger, `lcm` sends ordinary history without a summarizer call. At the trigger, it summarizes complete older conversation units in chunks. The request then contains ordered summary nodes with source ranges, followed by a verbatim tail. The latest user/tool unit remains in the tail. Condensation joins older nodes into parents and keeps the children in SQLite. A failed summary does not advance the covered cursor. If a summary exceeds the size of its source, `lcm` retries with a smaller output limit and then stores a short source pointer. The original rows remain available.

The default-enabled `lcm-memory` extension provides four read-only tools. `lcm_list` pages through every stored fold in the current session, including nodes absent from the request view. `lcm_grep` searches literal text in raw history and summaries with paged results and optional node scope. `lcm_describe` returns a node's source range, children, and summary. `lcm_expand` reads bounded pages of the original text rows covered by a node. These tools remain enabled when the session switches from `lcm` to `rolling`. Image bytes remain in the transcript; the text tools show image metadata. The extension implements hierarchical memory. It does not implement the paper's large-file dispatcher, map operators, or subagent-only expansion.

The `lcm` section in `$ALBEDO_HOME/extensions.json` accepts the same setting names as `rolling`:

```json
{ "lcm": { "contextWindowTokens": 200000, "triggerPercent": 90, "tailPercent": 25 } }
```

`contextWindowTokens` is optional. Without an explicit setting or catalogued window, automatic LCM compaction stays off; `/compact` can still force it. The estimate uses byte counts. The newest whole unit can exceed the available window. In that case preparation reports the limit without discarding part of the unit.

## rolling

`rolling` projects history as four parts, in order:

1. the system prompt (including enabled extension context), which is never compacted
2. one incremental summary of the older conversation it has already evicted
3. a short recap built from recent user messages, quoted verbatim and bounded
4. the newest conversation tail, unchanged

It compacts when the estimated request reaches `triggerPercent` of the configured context window, so roughly the last 10% stays free for work. The tail keeps about `tailPercent` of the window. A cut is only made between whole conversation units, so an assistant tool call always keeps its result.

Each rolling compaction combines the previous summary with newly evicted history in a replacement summary. A long eviction is summarized in chunks of at most half the window, with the summary carried from chunk to chunk. The summarizer call has no tools. Rolling writes its summary and cut position only after a successful call. A provider failure leaves the previous projection and the transcript intact. A branch starts without rolling state.

The saved cut counts user messages, not projected items. Provider projection can merge or drop assistant output, but it keeps every user message in order, so the summary still applies after a provider or model change. A fingerprint over the evicted user messages resets the state when the transcript no longer matches. A cut saved as an item count, before this format, is still checked the old way once and then rewritten in the new form.

After a switch from `lcm` to `rolling`, rolling reads the stored LCM summary nodes and the unsummarized tail as its source history. It does not expand covered rows to rebuild the LCM summary. If new assistant or tool rows follow the covered cursor without a new user row, rolling retains their whole conversation unit; that unit can overlap the fold. A later rolling summary can omit details from an LCM node. `lcm_list`, `lcm_describe`, and `lcm_expand` still reach the stored node and its original rows. Switching back to `lcm` uses its saved nodes and the durable transcript; it does not summarize the rolling summary.

## snapcompact

`snapcompact` archives evicted history as rendered bitmap frames that a vision model reads directly, instead of a model-written summary. The frames are X11 8x13 pixel-font text drawn by the local `albedo-render` binary and cached in `snapcompact_frames` by geometry and content. The request contains the frames, then the verbatim tail.

The saved archive is the normalized text of everything before the cut, stored in `snapcompact_archive` with a user-message cut like rolling's. Frames are re-derived from that text for each request, so after a model switch the same archive renders in the new model's frame shape. Recompaction appends newly evicted history to the saved text. Unchanged leading frames keep their cache keys, so the request prefix stays stable.

The archive keeps at most a frame budget, the smallest of:

- the provider's image budget, from oh-my-pi: 90 for `anthropic`, `amazon-bedrock`, and `openrouter`, 200 for `openai`, `openai-codex`, and the Google providers, 10 for `umans`, and 5 for any other provider or a model no catalog knows. albedo's `claude` and `antigravity` providers take 90, since antigravity also serves Claude models.
- 60 frames of inline image data (3 MB at about 50 KB a frame), except on `claude`, which uploads images through the files API
- 80 frames
- `archivePercent` of the window at the estimated cost of one full frame

When the archive exceeds the budget, whole frames between the first frame and the newest are dropped. The first image's caption then states how many characters were dropped.

Other strategies' stored folds stay as text ahead of the frames, so the budget only drops raw rows. `snapcompact` requires `snapcompact-memory`, which keeps the archive readable after a switch: another strategy receives it as text pages through `context.prior`, and the pages stand in for exactly the history the archive's cut covers. `snapcompact-memory` also provides `transcript_grep` and `transcript_read`, which search and page the session's full durable transcript, including history a frame renders illegibly or the budget dropped.

When the catalog reports that the current model reads no image input, `snapcompact` uses rolling's text compaction for that model. The frame archive stays saved for a later model that reads images. A model without catalog modalities is treated as vision-capable.

```json
{ "snapcompact": { "contextWindowTokens": 200000, "triggerPercent": 90, "tailPercent": 10, "archivePercent": 20, "maxFrames": 60 } }
```

`contextWindowTokens` and `maxFrames` are optional. `maxFrames` replaces the provider caps.

## configure

```json
{ "rolling": { "contextWindowTokens": 200000, "triggerPercent": 90, "tailPercent": 25 } }
```

Put this in `$ALBEDO_HOME/extensions.json`. `contextWindowTokens` is optional. Without it, `rolling` reads the current model's context window from the enabled [models catalog](models.md). An explicit setting takes precedence. Without either source, `rolling` does not compact automatically and `/context` reports an unknown window.

Estimates are local byte-based approximations, never provider token accounting. Image payloads are sized by their dimensions, not by base64 length, so an attached image cannot fake a million-token conversation.

Image bytes are never copied into the recap or the summarizer prompt; a recent image stays unchanged while its unit is in the tail.

## inspect

`/context` shows the prepared request: its sections in order, their sources, and compaction status. After a provider completes that request, it shows the provider's measured input tokens (and cached tokens when reported); until then, or when usage is omitted, the strategy's local estimate is shown instead. The JSON retains `estimated_input_tokens` separately from `provider_input_tokens` so neither is mistaken for the other. A manual `/compact` sends no ordinary provider request, so its snapshot has only an estimate. See [the context inspector](context.md).
