# usage feed

provider usage and quota, through [provide-usage](https://next.tangled.org/ptr.pet/provide-usage): a pure Zig core (`usage-core`) that knows each provider's rules, and an albedo driver that owns every byte of I/O. the daemon never grows provider-specific quota code; a new provider is a `usage-core` bump plus the pinned flake input moving.

## the split

`usage-core` never opens a socket, reads a clock, or touches the filesystem. a provider is a state machine: given a credential and the responses so far, `usage advance` says either which requests to send next or the finished report. albedo sends those requests, hands the bodies back, and repeats. one feed is a handful of round trips at most.

the driver is two files:

- [`src/albedo/harness/usage_feed.gleam`](../src/albedo/harness/usage_feed.gleam) — the loop, the envelope, and the report types. `fetch(provider, credential, now_ms)` runs a feed to completion. a provider failure (a 4xx, an unknown provider, a flaky `bl`) is data: `Ok(Report(error: Some(..)))`. `Error` means the driver itself failed: the binary is missing, its output is unparseable, or the feed did not finish in 6 rounds.
- [`src/albedo/harness/albedo_usage_core.erl`](../src/albedo/harness/albedo_usage_core.erl) — the I/O half: one `usage advance -` process per round, `http` requests through [`albedo_http`](extensions.md), and `command` execution.

each round is a fresh process fed one JSON envelope line on stdin: `{"provider", "credential", "responses": [round, ...], "nowMs"}`. the envelope carries the credential, so it never reaches argv where other local processes could read it. the host keeps the state (it resends every round's responses) and the core keeps the rules; neither holds anything the other could corrupt. an erlang port cannot half-close stdin, and the CLI stops reading at the first newline, so the driver writes the line and reads stdout to exit: one step line per replayed round, the last line is the answer.

the binary resolves like `albedo-render`: `priv/bin/usage` first, then `PATH`. `ALBEDO_USAGE_CORE` overrides both — tests point it at a fake, and a value that does not exist is an error, never a silent fallback.

## requests and responses

a step asks for requests; each is answered with one `{"status", "body"}` object:

- `http` — sent through albedo's one httpc front door, verified TLS and all. a transport failure is data: status `0` with the reason in the body, so a feed reports it instead of the call failing.
- `command` (alibaba's `bl`) — run with only `PATH`, `HOME`, `LANG`, `LC_ALL`, `LC_CTYPE`, `TZ` and the proxy variables in the environment, a timeout (the request's `timeoutMs`, 15 s by default), and a 64 KiB stdout cap. `127` means "this host will not run commands" and is reserved; a command that cannot be found or timed out answers `126`, and the feed routes around either the same way.

## packaging

The driver's timeout cleanup requires a `kill` executable on `PATH`. It sends `KILL` to the child process because closing the Erlang port alone does not guarantee that the child exits.

`usage-core` is a pinned tarball flake input (`flake = false`) on the knot, built in `default.nix` with nixpkgs' zig (its `build.zig.zon` demands 0.16.0, which nixpkgs-unstable carries). the CLI is linked into the daemon next to `albedo-render`:

```
nix build .#albedo.usageCore   # the derivation alone
nix build .#daemon              # the whole daemon, priv/bin/usage included
```

## consumers

the daemon-side poller (per-account quota) reads `Report` and `Limit` and records what arrives; nothing else should parse the core's JSON. `Limit.resets_at` is epoch milliseconds; `used_percent` is clamped 0–100; absent optionals mean the provider did not state the value, never "zero".
