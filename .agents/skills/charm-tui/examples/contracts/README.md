# Runnable contract exercises

These are original, dependency-free Go fixtures for two lessons: invalidating asynchronous search results when intent changes, and allocating body rows without negative sizes. They are not a Bubble Tea implementation or a new component library.

Run from this directory with Go 1.23 or newer:

```sh
go test -v ./...
go test -race ./...
```

Translate the state fields and guards into the existing UI model rather than adding this module to an application. A real adapter must also manage cancellable backend contexts, debounce/timer commands, focus and key routing, stable row identity, and terminal rendering.

The search fixture uses a clear-on-query-change policy. Retaining previous results is also valid, but requires an explicit stale/refreshing presentation. This latest-result policy applies to read-only search, not automatically to writes whose effects may already be committed remotely.

**What these tests do not prove:** actual cancellation, resource cleanup, Unicode display widths, Lip Gloss geometry, Bubbles behavior, terminal restoration, or any application integration. The state is single-owner and deliberately not thread-safe. The race test runs this fixture; it is not evidence about an upstream Charm application's concurrency.

See [architecture and effects](../../references/architecture-and-effects.md) and [testing and release](../../references/testing-and-release.md) for integration obligations.
