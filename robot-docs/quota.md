# quota

Provider quota is polled per account, once per daemon, and recorded as raw readings. Nothing is derived at record time: percentages, windows, reset times, statuses, and errors are stored exactly as the usage feed reported them, so later analysis can recompute anything from the rows. This is the phase-1 half of cache- and quota-aware compaction; a meter estimator reads these rows on demand.

## accounts

One poller, started with the daemon, maps every account albedo can see onto a [provide-usage](https://next.tangled.org/ptr.pet/provide-usage) provider id and credential:

- Each OAuth account in a provider's rotation pool: Claude accounts under `creds.json`'s `anthropic` account key poll as `anthropic`, ChatGPT accounts under `openai-codex` as `openai-codex`, Google accounts under `google-antigravity` as `google-antigravity` (with `extra.projectId`). Credentials come from the same readers the request path uses, and a stale token is refreshed through the provider extension's own refresh path under the credential lock, so polling refreshes tokens exactly the way requests do. Only the access token crosses into the core: the refresh token stays home, since albedo does all the refreshing and the core never reads one. A refresh that fails keeps the stored credential: the poll then records the auth failure as a reading instead of dropping the account. An account stored without a refresh token can never be refreshed and is kept the same way.

  Google Antigravity tracks quota limits per model family (`gemini`, `claude`, `gpt-oss`). When an Antigravity account hits a 429, the limit is recorded against that specific meter under `limitedMeters` in `creds.json` instead of walling the entire account. The quota poller also heals legacy `limitedUntil` marks: when poll readings for an Antigravity account arrive, if its `limitedUntil` matches any meter's `resets_at`, it is re-keyed to that meter in `limitedMeters` and the legacy field is cleared; an unmatched mark is cleared too, so the account re-learns its limits from the wire.
- Profiles in `config.json`: an `alibaba` profile polls as `alibaba` with a `cli` credential — the feed runs the signed-in `bl` CLI. A generic `openai` profile maps by its `baseUrl` host: `hyper.charm.land` polls as `hyper`, `api.deepseek.com` as `deepseek`, both with the profile's API key from `creds.json`. A profile whose host has no feed is skipped.

The account label is always non-secret: an email, an account id, a short hash of a refresh token, or a profile name.

## cadence

Each account is polled on its own schedule; two polls of one account never overlap. The default cadence is 10 minutes. An account moves onto the 2-minute busy cadence while any limit is at or above 80 percent or resets within 15 minutes. A failed poll (a driver failure or a report carrying an error) backs off, doubling each time up to an hour. Account discovery re-runs on the ordinary cadence, off the poller, so a refresh never blocks scheduling; new accounts poll immediately, and an account that is mid-poll when it disappears finishes first.

Settings live in `$ALBEDO_HOME/extensions.json` under `"quota"`, read like any extension's settings and re-read every round, so changes apply without a restart:

```json
{ "quota": { "pollSeconds": 600, "busyPollSeconds": 120, "enabled": true } }
```

`enabled: false` stops polling and drops the account list; the readings already stored stay readable.

## readings

`quota_sample` in `albedo.sqlite` holds one row per limit a report carried: the account label, provider id, the report's plan (what 100 percent means changes with it), limit id and label, used percent, the window label and window seconds, reset time (epoch milliseconds), scope, status, the report's error when it failed, the observation time, and the source (`poll`). A report with an error and no limits stores one row carrying the error; a missing percentage stays null rather than becoming zero, so unknown is never mistaken for empty.

The feed itself is `albedo/harness/usage_feed`: a stateless `usage advance -` round loop whose HTTP and command I/O runs through albedo. `Error` from the feed means the driver failed (missing binary, unparseable output); a provider failure arrives as a report with an error, which is data.

## reading them back

Quota readings are served by `GET /server`:

- The base response carries `quota`, a list of the latest reading per account and limit, capped at 200 observations, read-only.
- A poll that failed with no limits is filed under the empty limit id, where only another such failure ever replaces it. `quota` drops one once a later reading of any real limit of the same account and provider exists, because the account is answering again; an account that only ever fails keeps its failure. (Without this a one-off error stayed "the latest reading" for days beside healthy limits.)
- Adding `include=quota_history` pages raw stored samples newest-first under `quota_history` with `items` and opaque continuation cursor `next`. Keyset pagination uses row ID with `limit` capped at 200 (default 50).
- History can optionally be filtered to a single limit trail using query parameters `quota_provider`, `quota_account`, and `quota_limit`. All three must be supplied together.
- A filtered trail query can optionally supply `quota_since` as an RFC 3339 UTC timestamp to constrain history to observations at or after that time (`observed_at >= since`). `quota_since` is only valid together with the three filter parameters above.
- Pagination continuations (`next`) are cryptographically bound to the query parameters; a cursor minted for one set of filters cannot be used with another.

## hermetic tests

The provider URLs live inside the usage core, so `test/e2e/quota_test.py` points `ALBEDO_USAGE_CORE` at a fake `usage` executable that answers the envelope with scripted reports (anthropic ordinary, hyper busy, deepseek failing), with short poll settings; it asserts readings land for all three account shapes and that history pages. The override is authoritative: a nonexistent value errors rather than falling back, so the fake is the whole feed for that daemon.

Each cadence is asserted as the interval between one account's consecutive readings — the median hyper interval at `busyPollSeconds`, the ordinary account at `pollSeconds`, the failing account's intervals growing past the ordinary cadence — not as poll counts over wall time, which race the machine rather than measure the schedule. The fake answers even a bad envelope or its own vanished directory with an error report instead of crashing: a crashed fake would exit 1 and read as a driver failure, so the fake failing loudly and the test failing on any reading whose error names the driver keeps the two halves distinguishable.

## source references

`albedo/daemon/quota.gleam` owns the poller, the table, and the read path. The poller takes its fetch function as a parameter, so tests can drive it against a fake. The per-provider account listing lives with each provider's credentials: `albedo_claude_auth:accounts/1`, `albedo_openai_auth:accounts/1`, and `albedo_antigravity:accounts/1`. `albedo/daemon/registry.gleam` initializes the table in `prepare_storage`. `albedo/daemon/server.gleam` starts the poller under the daemon supervisor and exposes its route.

## the `/quota` screen

The terminal client's `/quota` (`cli/internal/tui/quota.go`, `quota_view.go`) shows the latest reading of each limit, grouped by provider and account, with a bar, the percent and a reset countdown; the pane beside it shows the highlighted limit's trail. It reads `quota` once, and `include=quota_history` with the four filters for the limit under the cursor, as that limit is first highlighted (`GetLatestQuota`, `GetQuotaTrail`).

- A trail is read back as far as the limit's window, at least a day and at most a week, from at most five pages of 200 rows. A busy limit polls every two minutes, so a week of it can overflow that cap: the pane then labels the trail with the span it really has (`quotaTrailFrom`), not the span it asked for. The oldest readings are the ones dropped.
- A reading is stale when it is older than 30 minutes or past its own reset; its bar goes faint and the countdown becomes `seen 3h`. A trail stops where polling stopped.
- `ctrl+r` reloads the readings and forgets every trail, so the highlighted limit asks again.
- `/ttl` and `/requests` are still the generic inspector pages; `/quota` no longer is.
