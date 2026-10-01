# cache TTL table

The prompt-cache TTL table is the prior the cache-warmth estimate starts from: how long each provider keeps a cached prefix, what a write costs, and whether a hit restarts the clock. It answers `lookup(extension, host, model)` in `src/albedo/harness/cache_ttl.gleam` until a session's provider requests have measured the real thing (robot-docs/provider-requests.md); after that the measurements win.

The table is data, not code: `priv/cache-ttl.json` ships with the daemon, and nothing about a provider is hardcoded anywhere else.

## format

A file is `{"version": 1, "entries": [...]}`. One entry:

- `id` — unique within a layer. Layers replace entries by it.
- `match` — which requests the entry describes: `extension` (albedo's extension name: claude, codex, openai, antigravity, alibaba, ...), `host` (endpoint host), `model` (model id). Each is one string or a list; each string is a glob where only `*` is special: it matches any run of Unicode graphemes, case-insensitively. Matching has bounded polynomial work even for repeated wildcards. An absent field matches anything; a list matches if any element does.
- `policy` — `refresh` (every hit restarts the lifetime), `fixed` (lifetime runs from the write), `evict` (no clock, best-effort, only survival windows are known), or `unknown`.
- `clock` — `request` or `response` (default `response`): whether a lifetime counts from request start or response end. Anthropic counts from request start, so streaming time uses the cache up.
- `tiers` — the TTLs a request can ask for, each `{seconds, write}` with the write-price multiplier.
- `read` — the read-price multiplier, when the provider charges for hits.
- `survival` — `{typical, max?}` seconds, for `evict` and `unknown` entries.
- `evidence` — `documented`, `measured`, `implemented`, `folklore`, or `unknown`.
- `source` (url), `checked` (date), `note` (text).

Unknown fields are ignored, so a newer file stays readable. An entry without a string `id`, or with an invalid `policy`, `evidence`, or other field, is skipped with a logged reason. An absent `match` matches anything. Repeated string ids within one layer reject that layer, even when one of the entries would fail semantic decoding; the layer keeps its last good entries. The same id in different layers is a valid override.

**Values marked `folklore` or `unknown` are placeholders.** They are the shape of the answer, not the answer: phase 2 replaces them with what the session's own request rows measure.

## layers

Three layers merge by id:

1. `default` — the shipped `priv/cache-ttl.json`.
2. `remote` — a copy fetched by default from [this repo's `priv/cache-ttl.json` on `main`](https://api.next.tangled.org/xrpc/org.tangled.temp.git.getBlob?repo=did%3Aplc%3Al7hhzcbqqvpcquau5waryzdu&ref=main&path=priv%2Fcache-ttl.json), cached at `$ALBEDO_HOME/cache-ttl-remote.json`. In `$ALBEDO_HOME/extensions.json`, set `cacheTtl.url` to another JSON file to override it, or `null` to disable remote fetching. `refreshHours` defaults to 24; `0` disables the background refresh (but not explicit `/reload`). Only `https`, or `http` on the loopback host, is fetched, the response is capped at 1 MiB, and the write is a rename — a failed fetch keeps the previous copy.
3. `local` — `$ALBEDO_HOME/cache-ttl.json`, for hand edits.

A later layer replaces an entry with the same id in place, and puts entries with new ids **before** all earlier-layer entries, so a local override can shadow a general default while the shipped specific-to-general order survives underneath. Merging lives in `src/albedo/harness/cache_ttl.gleam`; file reads, fetching, and revision caching stay in `albedo_cache_ttl.erl`. Entries are merged before full decoding, so an invalid same-id override shadows the earlier entry and is then skipped. Within the merged table, **first match wins** a lookup: the files list specific entries before general ones, and that order is the precedence.

## reload

Each layer file is parsed once per revision (size + mtime), including malformed JSON, invalid table shapes, and duplicate-id failures. The merged decoded Gleam table is cached; a changed file is picked up on the next lookup without a restart. A malformed layer file keeps that layer's last good entries and reports the reason in `/cache-ttl`; fixing the file at a new revision is live again. Transient file-read errors are retried on the next read and retain last good entries. HTTP responses encode the cached table only when serving it.

The remote copy refreshes in the background when it is stale, the same cadence as the models catalog. `/reload` (no target) re-fetches it immediately, alongside the models catalog: the command returns after the copy is atomically replaced, or with the fetch failure. A fetched layer with duplicate ids is rejected before replacing the file. A confirmed replacement invalidates the parsed layer and merged table even when size and timestamp stay unchanged.

## local api

`GET /cache-ttl`, read-only, daemon-token authenticated like `/quota`:

- no parameters — `{"entries": [...], "layers": [{"name": "default"|"remote"|"local", "path", "loaded", "error"?}]}`, each entry carrying the layer it came from and every field above it decoded.
- `?extension=&host=&model=` — the single resolved entry, or `null`, resolved exactly as `lookup` resolves it.

`layers` is the state of each file: `loaded` false with an `error` means that layer's last good entries are still merged in (or it was never readable). An absent local override or unconfigured remote url is simply not loaded, with no error.
