# Context inspector

`/context` opens a read-only view of the most recently prepared model request for the current session. It does not prepare history, compact the transcript, invoke a tool, or contact the provider. Before the first provider request, and after a model, workspace, or extension reload changes request composition, the inspector remains explicitly pending until the next request is prepared.

The daemon records the same `Request` value passed to the provider on every model/tool-loop iteration. Recording occurs after extension context and any selected compaction strategy have prepared history, immediately before the provider call. A refresh therefore observes the last actual request; it does not predict the next one.

## Request composition

Sections appear in provider request order:

1. system instructions
2. one section per enabled extension context item
3. prepared conversation history
4. enabled tool schemas

Each section names its source and reports exact item and byte counts for its underlying prepared request value. Byte counts measure UTF-8 request content or the exact encoded provider tool schema, not displayed terminal width. Compaction token counts are labeled estimates with their method; they are not provider usage. A configured context-window limit is shown only when it is known.

The summary endpoint returns only bounded previews. Full inspectable text is available in bounded 8,000-character pages. Image base64 bodies and opaque provider replay bodies are never copied into inspector pages; the page names each omission while preserving its position and available image metadata. Provider credentials are not part of the recorded request.

## Local API

Authenticated local clients use GET requests only:

- `GET /sessions/:id/context` returns pending state or request metadata and ordered section summaries.
- `GET /sessions/:id/context/:section/:page` returns one bounded, zero-based content page.

The `session_context` health capability indicates support. Invalid section or page identifiers return an error without changing session state.
