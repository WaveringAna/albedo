# compaction

Compaction changes only what a request shows the model. The durable transcript, `/tree`, and forks always keep the full conversation.

At most one enabled compaction strategy owns the request view of history. `rolling` is enabled by default; `lcm` is installed but disabled until selected for a session. Disable `rolling` before enabling `lcm` through `/extensions`.

A strategy returns its prepared inputs with an observation for `/context`.
The observation belongs to that exact preparation; the inspector does not
read a particular strategy's saved state. The saved transcript remains the
source of truth when a strategy's derived view is rebuilt.

## source references

`conversation.load_sources` reads transcript rows with `SourceRef(session, seq)`,
and `conversation.source` resolves one reference. The sequence is SQLite's
append-only transcript identity; a fork copies rows into its own session and
gets new references. Derived compaction state should therefore be scoped to a
session and rebuilt for a fork.

Provider projection can combine several durable rows into one model input,
split one row into several inputs, or omit a nonportable reasoning item.
`projection.for_model_with_sources` records all rows that produced each
projected input while `projection.for_model` continues to return plain inputs
for existing callers. Synthetic extension context and strategy-created
summary inputs have no transcript reference.

`lcm` uses durable source rows for its summary ranges and the existing plain
model projection for its verbatim tail. It preserves every unsummarized user
unit and the latest whole user/tool unit. Carrying references with each live
projected input would let future strategies make finer cuts without relying
on those unit boundaries.

To carry references through live turns, the session coordinator should retain
the inserted sequence IDs from the same transaction that commits inputs, then
project those identified entries before preparing a request. Its current
commit callback returns only a timestamp, and its in-memory entries have no
sequence field. Keep the existing plain-input path for callers that do not
need provenance. Matching rows later by text or list position would be unsafe:
messages can repeat and provider projection can change item counts. A marker
for an excursion belongs to its parent session; the branch's copied rows have
their own references, so returning an outcome requires an explicit link to
the parent marker.

## lcm

`lcm` implements the source-backed memory part of [Lossless Context
Management](https://arxiv.org/html/2605.04050v1). It keeps the existing
transcript as the authority and writes derived leaf summaries, condensed
parent summaries, their child links, and a covered source cursor into SQLite.
The summary tree is scoped to one session. A fork has its own transcript
identities and starts with a fresh tree.

Before the configured trigger, it sends the ordinary history without a
summarizer call. On compaction, it summarizes complete older conversation
units in chunks. The model request then sees ordered source-labelled summary
nodes followed by a verbatim tail. The latest user/tool unit always stays in
that tail. Summaries have source ranges; condensation joins older nodes into
parents whose children remain in the database. A failed provider summary does
not advance the covered cursor. If a summary grows beyond its source, the
extension retries with a smaller output cap and then uses a short source
pointer, so the original remains retrievable.

The model gets three read-only tools: `lcm_grep` searches literal text in raw
history and summaries with paged results and optional node scope;
`lcm_describe` shows a node's range, children, and summary; `lcm_expand` reads
bounded pages of the original text rows covered by a node. Expansion is
page-limited in the main session. Image bytes remain in the transcript, but
these text tools show image metadata rather than returning the image to the
model. This first extension covers hierarchical memory, not the paper's
large-file dispatcher, map operators, or subagent-only expansion.

The same settings names as `rolling` apply under an `lcm` section in
`$ALBEDO_HOME/extensions.json`:

```json
{ "lcm": { "contextWindowTokens": 200000, "triggerPercent": 90, "tailPercent": 25 } }
```

`contextWindowTokens` is optional. With no explicit setting or catalogued
window, automatic LCM compaction stays off; `/compact` can still force it.
The estimate is byte-based and the newest whole unit may itself exceed the
available window, in which case preparation reports that limit rather than
discarding part of the unit.

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
