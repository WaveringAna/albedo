# web search

the model gets one search, `await web_search(query, limit=8)`, whatever is signed in. it answers with a record: `answer` (written prose, empty from a plain engine) and `sources`, each with `title`, `url`, `snippet`, and `published`; printing it shows the answer and numbered sources. the model is told only that, not which provider answered or why another was passed over.

## providers

a provider is a `SearchPlugin(web_search.Provider(name, label, search))` on the extension that owns its sign-in, so credentials, account rotation, and wire formats stay where they already live. `search(Query(text, limit, session))` answers `Result(Answer, String)`; the error is a short reason the fallthrough can list. shared types and helpers are in [`harness/web_search.gleam`](../src/albedo/harness/web_search.gleam): `distinct` dedupes sources by url and cuts them to the limit, `failure` words a transport error, and `listen` folds a streamed exchange's payloads into a state for providers whose answer arrives as SSE.

| extension | name | how it searches |
| --- | --- | --- |
| `codex` | `codex` | the ChatGPT backend's Responses with the hosted `web_search` tool forced; sources are the answer's `url_citation`s, then what the search call turned up. `utm_source=openai` is stripped. |
| `claude` | `claude` | Messages with the server tool `web_search_20250305` (`max_uses` 5) appended through `wire.encode_with`; sources are `citations_delta`s, then `web_search_tool_result` pages. |
| `antigravity` | `antigravity` | Cloud Code `streamGenerateContent` with `googleSearch` grounding through `wire.encode_with`, at the model's lowest effort. grounding chunks are Google redirect urls; `albedo_http:locations` resolves each with one HEAD, all at once, 5s, keeping the redirect when it fails. |
| `exa` | `exa` | Exa's `/search` with highlights as snippets. no prose. |

the subscription providers refuse an answer that never searched (no search call, no grounding): it would be the model's memory passed off as a search result. each one checks its sign-in before resolving a model, so a signed-out provider fails at once without reaching the network. `searchModel` in that extension's section of `extensions.json` picks the model; otherwise codex uses the account's first listed model, claude the newest listed model, and antigravity the first listed Gemini.

exa reads its key from `creds.json` as `{"exa": {"apiKey": "..."}}`; `{"exa": {"endpoint": "..."}}` in `extensions.json` points it at another host (the e2e suite points it at a fake).

## order

the `web-search` extension collects every installed `SearchPlugin` when the daemon composes its extensions (`extensions.defaults`), so a provider is offered whether or not its extension is enabled; a signed-out one simply fails and is passed over. a search tries the providers top to bottom and returns the first answer that says anything; a failure or an empty answer moves to the next, and when all fail the call raises with every reason, `name: reason`, in order.

the order is global, in `extensions.json`:

```json
{ "web-search": { "order": ["claude", "codex", "antigravity", "exa"], "off": ["exa"] } }
```

names `order` leaves out follow it in registry order; names in `off` are never tried. `/web-search` is the page for it: `u` and `d` move the selected provider, `t` turns it on or off, and each change writes both lists. the service is `GET /extensions/web-search/providers` and `POST /extensions/web-search/providers/{name}` with `{"change": "up" | "down" | "toggle"}`; a move past either end changes nothing. see [OpenAPI](../docs/openapi.yaml).

tests: `test/e2e/web_search_test.py`.
