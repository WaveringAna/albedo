# Context inspector

`/context` opens a read-only view of the most recently prepared model request for the current session. It does not prepare history, compact the transcript, invoke a tool, or contact the provider. Before the first provider request, and after a model, workspace, or extension reload changes request composition, the inspector remains explicitly pending until the next request is prepared.

The daemon records the same `Request` value passed to the provider on every model/tool-loop iteration. Recording occurs after extension context and any selected compaction strategy have prepared history, immediately before the provider call. A refresh therefore observes the last actual request; it does not predict the next one.

## Request composition

Sections appear in provider request order:

1. system instructions
2. one section per enabled extension context item
3. prepared conversation history
4. enabled tool schemas

Each section names its source and reports exact item and byte counts for its underlying prepared request value. Byte counts measure UTF-8 request content or the exact encoded provider tool schema, not displayed terminal width. The compaction observation keeps its local `estimated_input_tokens` and method. Once the provider completes that prepared request, `/context` also reports `provider_input_tokens` and, when available, `provider_cached_input_tokens`; the inspector displays the measured input instead of the estimate. Cached tokens are a subset of the reported input, not an amount to add. A provider that omits usage leaves the estimate as the fallback, and a new request starts without the preceding request's measurement. The configured context-window limit is shown only when it is known.

The summary endpoint returns only bounded previews. Full inspectable text is available in bounded 8,000-character pages. Image base64 bodies and opaque provider replay bodies are never copied into inspector pages; the page names each omission while preserving its position and available image metadata. Provider credentials are not part of the recorded request.

## Local API

Authenticated local clients use GET requests only:

- `GET /sessions/:id/context` returns pending state or request metadata and ordered section summaries.
- `GET /sessions/:id/context/:section/:page` returns one bounded, zero-based content page.

The session actor owns the immutable prepared snapshot and returns it to the caller. Summary and page rendering run in the calling process, so rendering does not occupy the session actor. Each read uses one captured snapshot.

The `session_context` health capability indicates support. Invalid section or page identifiers return an error without changing session state.

The skills and instructions management catalog at `GET /sessions/:id/catalog` is a fresh discovery view, separate from this prepared request snapshot. A candidate can appear there before a session reload makes it available at runtime; reloads can also update live commands while the cached system prompt remains pinned until compaction.
