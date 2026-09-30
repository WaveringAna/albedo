# quota

Provider quota is polled per account, once per daemon, and recorded as raw readings. Nothing is derived at record time: percentages, windows, reset times, statuses, and errors are stored exactly as the usage feed reported them, so later analysis can recompute anything from the rows. This is the phase-1 half of cache- and quota-aware compaction; a meter estimator reads these rows on demand.

## accounts

One poller, started with the daemon, maps every account albedo can see onto a [provide-usage](https://next.tangled.org/ptr.pet/provide-usage) provider id and credential:

- Each OAuth account in a provider's rotation pool: Claude accounts under `creds.json`'s `anthropic` account key poll as `anthropic`, ChatGPT accounts under `openai-codex` as `openai-codex`, Google accounts under `google-antigravity` as `google-antigravity` (with `extra.projectId`). Credentials come from the same readers the request path uses, and a stale token is refreshed through the provider extension's own refresh path under the credential lock, so polling refreshes tokens exactly the way requests do. Only the access token crosses into the core: the refresh token stays home, since albedo does all the refreshing and the core never reads one. A refresh that fails keeps the stored credential: the poll then records the auth failure as a reading instead of dropping the account. An account stored without a refresh token can never be refreshed and is kept the same way.
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

`GET /quota` serves the latest reading per account and limit, read-only:

```json
{ "readings": [ { "id": 41, "account": "charm-hyper", "provider": "hyper",
                  "plan": null, "limitId": "primary", "label": "Primary",
                  "usedPercent": 85.0, "windowLabel": "1 hour", "windowSeconds": 3600,
                  "resetsAt": 1760000000000, "scope": null, "status": "ok",
                  "error": null, "observedAt": 1759999400000,
                  "source": "poll" } ] }
```

`GET /quota?history=<id>` pages the raw samples newest-first by row id (`history=0` starts at the newest, `limit` caps the page at 200), answering `{ "items", "nextCursor", "hasMore" }` like the other paged routes. The route queries the store directly and writes nothing.

## hermetic tests

The provider URLs live inside the usage core, so `test/e2e/quota_test.py` points `ALBEDO_USAGE_CORE` at a fake `usage` executable that answers the envelope with scripted reports (anthropic ordinary, hyper busy, deepseek failing), with short poll settings; it asserts readings land for all three account shapes and that history pages. The override is authoritative: a nonexistent value errors rather than falling back, so the fake is the whole feed for that daemon.

Each cadence is asserted as the interval between one account's consecutive readings — the median hyper interval at `busyPollSeconds`, the ordinary account at `pollSeconds`, the failing account's intervals growing past the ordinary cadence — not as poll counts over wall time, which race the machine rather than measure the schedule. The fake answers even a bad envelope or its own vanished directory with an error report instead of crashing: a crashed fake would exit 1 and read as a driver failure, so the fake failing loudly and the test failing on any reading whose error names the driver keeps the two halves distinguishable.

## source references

`albedo/daemon/quota.gleam` owns the poller, the table, and the read path. The poller takes its fetch function as a parameter, so tests can drive it against a fake. The per-provider account listing lives with each provider's credentials: `albedo_claude_auth:accounts/1`, `albedo_openai_auth:accounts/1`, and `albedo_antigravity:accounts/1`. Startup wiring is in `albedo/daemon/server.gleam`: the table in `prepare_storage`, the poller under the daemon supervisor, and the route among the daemon's own.
