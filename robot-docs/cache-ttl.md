# cache TTL table

The prompt-cache TTL table is the prior the cache-warmth estimate starts from: how long each provider keeps a cached prefix, what a write costs, and whether a hit restarts the clock. It answers `lookup(extension, host, model)` in `src/albedo/harness/cache_ttl.gleam` until a session's provider requests have measured the real thing (robot-docs/provider-requests.md); after that the measurements win.

The table is data, not code: `priv/cache-ttl.json` ships with the daemon, and nothing about a provider is hardcoded anywhere else.

## format

A file is `{"version": 1, "entries": [...]}`. One entry:

- `id` — unique. Layers replace entries by it.
- `match` — which requests the entry describes: `extension` (albedo's extension name: claude, codex, openai, antigravity, alibaba, ...), `host` (endpoint host), `model` (model id). Each is one string or a list; each string is a glob where `*` matches any run of characters, case-insensitively. An absent field matches anything; a list matches if any element does.
- `policy` — `refresh` (every hit restarts the lifetime), `fixed` (lifetime runs from the write), `evict` (no clock, best-effort, only survival windows are known), or `unknown`.
- `clock` — `request` or `response` (default `response`): whether a lifetime counts from request start or response end. Anthropic counts from request start, so streaming time uses the cache up.
- `tiers` — the TTLs a request can ask for, each `{seconds, write}` with the write-price multiplier.
- `read` — the read-price multiplier, when the provider charges for hits.
- `survival` — `{typical, max?}` seconds, for `evict` and `unknown` entries.
- `evidence` — `documented`, `measured`, `implemented`, `folklore`, or `unknown`.
- `source` (url), `checked` (date), `note` (text).

Unknown fields are ignored, so a newer file stays readable. A bad entry — missing `id`, `match`, `policy` or `evidence`, or a value that does not decode — is skipped with a logged reason and never fails the table.

**Values marked `folklore` or `unknown` are placeholders.** They are the shape of the answer, not the answer: phase 2 replaces them with what the session's own request rows measure.

## layers

Three layers merge by id:

1. `default` — the shipped `priv/cache-ttl.json`.
2. `remote` — a copy fetched from a url, cached at `$ALBEDO_HOME/cache-ttl-remote.json`:
   ```json
   { "cacheTtl": { "url": "https://example.com/cache-ttl.json", "refreshHours": 24 } }
   ```
   in `$ALBEDO_HOME/extensions.json`. Absent `url` means no fetch; `refreshHours: 0` disables the background refresh. Only `https`, or `http` on the loopback host, is fetched, the response is capped at 1 MiB, and the write is a rename — a failed fetch keeps the previous copy.
3. `local` — `$ALBEDO_HOME/cache-ttl.json`, for hand edits.

A later layer replaces an entry with the same id in place, and puts entries with new ids **before** all earlier-layer entries, so a local override can shadow a general default while the shipped specific-to-general order survives underneath. Within the merged table, **first match wins** a lookup: the files list specific entries before general ones, and that order is the precedence.

## reload

Each layer file is parsed once per revision (size + mtime) and the merged table is cached; a changed file is picked up on the next lookup without a restart. A malformed layer file keeps that layer's last good entries and reports the reason in `/cache-ttl`; fixing the file is live again.

The remote copy refreshes in the background when it is stale, the same cadence as the models catalog. `/reload` (no target) re-fetches it immediately, alongside the models catalog: the command returns after the copy is atomically replaced, or with the fetch failure.

## local api

`GET /cache-ttl`, read-only, daemon-token authenticated like `/quota`:

- no parameters — `{"entries": [...], "layers": [{"name": "default"|"remote"|"local", "path", "loaded", "error"?}]}`, each entry carrying the layer it came from and every field above it decoded.
- `?extension=&host=&model=` — the single resolved entry, or `null`, resolved exactly as `lookup` resolves it.

`layers` is the state of each file: `loaded` false with an `error` means that layer's last good entries are still merged in (or it was never readable). An absent local override or unconfigured remote url is simply not loaded, with no error.
