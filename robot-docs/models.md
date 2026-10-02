# models catalog

Persisted preferences are owned by the daemon and changed through the [settings API](settings.md). The CLI refreshes them on use and never writes settings files.


The `models` extension keeps a local copy of the [models.dev](https://models.dev) catalog and answers one question for the rest of Albedo: what is actually known about this model and its provider. It never guesses a limit from a model name.

It is enabled by default and contributes no model tools and no prompt context.

## cache

The catalog is cached at `$ALBEDO_HOME/models.json` (default `~/.albedo/models.json`). Albedo refreshes it when it is missing or older than the refresh window, in the background, and writes it by rename so a partial download is never readable. A failed fetch keeps the previous cache. The cached JSON keeps only the fields used by lookups and lists. Fetching, revision caching, and the persisted reduced index stay in `harness/extensions/models/albedo_models.erl`.

```json
{ "models": { "url": "https://models.dev/api.json", "refreshHours": 24 } }
```

Put this in `$ALBEDO_HOME/extensions.json`. `refreshHours: 0` disables automatic fetching and uses only the cached file, which is what the test suite and air-gapped hosts do. Only `https`, or `http` on the loopback host, is fetched.

Run `/reload models` to fetch the configured catalog immediately, regardless of its age or `refreshHours`. The command returns only after the cache has been atomically replaced, so the next `/model` picker reads the new model list. A failed fetch leaves the previous cache in place and reports the failure.

## lookup

A lookup takes the session's model id and its configured provider base url. The endpoint decides between providers that publish the same model id. The ChatGPT endpoint uses the OpenAI provider identity. Without a host match, the smallest positive context and output limits win, and modalities and efforts are intersected across candidates that report them. Empty capability lists mean unknown and do not constrain the intersection. A successful lookup preserves an empty effort list, including an empty intersection. Reasoning efforts are inferred from the name only when a valid catalog does not contain the model, never when the catalog is unavailable or malformed. The answer carries no guessed provider, API endpoint, or environment. Exact provider lookups never borrow another provider's facts. These selection rules live in `harness/extensions/models/catalog.gleam`, which returns typed model facts directly to its callers. Both the catalog key and its trailing segment resolve, so `vendor/model` and `model` find the same entry.

An answer carries the context window, the maximum output, the input modalities, the provider id, its documented API endpoint, and its expected environment variable names. Everything is reported with its source: the cached file and how the model was matched.

## used by

`rolling` compaction asks for the context window when `contextWindowTokens` is not configured, so compaction works without hand-configuring each model. An explicit setting still wins. `/context` shows the window and names where it came from; an unlisted model stays explicitly unknown.

Provider extensions consume the catalog's endpoint and environment metadata, so authentication and transport policy do not require the daemon to hardcode a model list.

## provider extensions

The catalog also lists model ids by provider or endpoint. `/login` and `/model` read those lists from this cache; only Codex also asks its own backend (see [codex models](#codex-models)). `GET /models/{provider}?endpoint=…` answers ids. With `&details=1` it answers `{id, efforts, context, maxContext, raised, output, input}` objects: the catalog's facts, the window a raised cap gives and whether it is raised, and the reasoning efforts a session accepts for that model. The `/model` picker lists every saved profile this way. The `openai` model-provider extension depends on `models` and owns API-key configuration plus the shared Responses/Chat Completions client. The `codex` extension depends on `openai`; it reuses that request stack and adds only ChatGPT OAuth, account selection, and Codex wire policy. The dependency chain is therefore `codex -> openai -> models`. `antigravity` has no dependencies: it brings its own catalog and sign-in, and its upstream drives `openai_api.exchange` with its own encoder and reducer. `claude` depends on `models`: it selects its current and fallback models from the cached Anthropic namespace, reads exact provider-scoped limits and efforts, and uses a Messages transport with Claude Code OAuth rather than the catalog's API-key credentials.

Saved provider profiles carry an `extension` tag. Existing profiles without one migrate as `openai`. Codex profiles use `extension: "codex"` and keep OAuth credentials separately in `$ALBEDO_HOME/creds.json`; see [model authentication](auth.md).

## codex models

Codex asks the ChatGPT backend which models it offers each signed-in account: `GET https://chatgpt.com/backend-api/codex/models?client_version=…`. The backend shows a model only to clients at or past its minimal client version, so albedo sends the latest released Codex CLI version, read from npm (`@openai/codex`), rechecked whenever a stale list is refreshed; a forced reload always rechecks it, so a released client version unlocks its models the moment you reload. A model OpenAI releases to Codex appears in `/model` without an albedo update, and no model name is hardcoded. The list is cached per account in `$ALBEDO_HOME/codex-models.json`: `/model` refreshes it when it is over an hour old, conditionally with the backend's ETag, and a Codex session start refreshes it in the background. Lookups read only the cache.

A Codex lookup answers for the ChatGPT endpoint with the backend's own facts: the default window (`context_window`), the maximum a raised cap gives (`max_context_window`, when larger), input kinds, and reasoning efforts, including levels models.dev does not list. Codex advertises `ultra` as a virtual tier that cannot be requested; the catalog excludes it from new responses and existing cached lists. models.dev's `openai` entry fills in what the backend leaves out, such as the output limit. A model the backend does not report falls back to that `openai` entry. `/effort`, session defaults, and model switches use this same selection.

## choosing a model from the command line

`albedo models` prints `provider/model` for every configured provider, the active provider first and each provider's default model first. `albedo -p <prompt> --model <model>` takes either spelling the agents' `spawn(model=...)` takes: `provider/model`, or a bare id, served by the active provider when it offers it and otherwise by the one provider that does. Only exact ids match; an id no provider lists, or one several list, is refused before a session is created. A new session starts on the model; with `--session`, `POST /sessions/:id/model` (`{model, provider}`, capability `session_model`) switches that session without making the model the default for new sessions, which `/model` does.

A persisted session without an effort selects the catalog default when its actor starts. The actor must save that effort before accepting work. A failed write leaves the session unavailable, logs the initialization failure, and retries on its next activation.

## raised caps

A provider can report a larger window than a session uses by default; Codex reports 272k by default and 872k at most for GPT-5.6 and GPT-6. Models degrade over long contexts, and published long-context results differ by model, so albedo uses the default until you raise the cap. `/raise-cap` or tab in the `/model` picker raises it for one model, saved in `$ALBEDO_HOME/extensions.json`:

```json
{ "raisedCaps": { "gpt-6-astra": true } }
```

Compaction, `/context`, and every session on that model then use the maximum from their next request. A catalog reports the maximum as `ModelInfo.max_context_tokens`; a model without one has nothing to raise.

## antigravity models

Antigravity is not on models.dev, and its model ids and required `model_enum` labels change server-side. The `antigravity` extension therefore contributes its own catalog. It asks Cloud Code Assist `fetchAvailableModels` which models the account can use, keeps the ids that the real client's agent picker shows, and caches them with their limits, labels, and the renames of retired ids in `$ALBEDO_HOME/antigravity.json`. The cache refreshes in the background after 6 hours, and the first `/login` listing waits for discovery. A built-in table supplies each model's thinking control and serves as the list before the first discovery. A saved profile that names a retired id follows the backend's rename. The catalog answers lookups only for the Antigravity endpoint, so models.dev keeps answering for the same ids at other providers.

## contribute another catalog

`extension.ModelsPlugin(ModelCatalog(lookup, list))` is the catalog contract. `lookup(model, endpoint)` returns facts for one model; `list(provider, endpoint)` returns ids owned by one catalog provider. The first enabled catalog with an answer wins, so a private or offline catalog can be installed ahead of models.dev.

A model transport contributes `ModelProviderPlugin(ModelProvider(catalog_provider, resolve))`. `catalog_provider` is the models.dev namespace used by `/login` and `/model`; `resolve` returns the profile's `extension.Upstream`: its endpoint, the replay protocol it produces, a `stream` function over albedo's request types, `explain`, which turns a provider failure into an actionable message, and `images`, the largest image edge every request it sends accepts (`extension.any_images`, albedo's own 16384px bound, when the provider states none). `openai` builds upstreams from the shared `openai_api` client with `openai.upstream`; a provider with another wire format supplies its own `stream`. Its extension should require the catalog or transport extension whose metadata and wire behavior it reuses. For example, `openai` declares the `openai` namespace, while `codex` also declares `openai` and inherits the shared transport through its dependency. New provider extensions get catalog-backed discovery by declaring their namespace. A provider whose backend reports its own models, as Codex does, can also answer from a `ModelsPlugin` of its own.

An `openai` profile declares albedo's own bound unless its `config.json` entry sets `"imageEdge"` (pixels), for an endpoint that takes smaller images; a login saves its profile through the daemon, which merges it into the stored one, so a hand-set value survives. `claude` declares 2000px. Anthropic takes an 8000px image on its own, but once a request carries more than 20 images every image in it, earlier turns and tool results included, must fit in 2000px, and a working session passes 20 quickly. A tool image over the limit never reaches the model: each cell carries the edge to the kernel, so `show_image` raises `ValueError: 2304x1212 image is over this model's 2000px edge limit` at the call and the model can show a smaller one (the daemon checks again and names any it still refuses under `image_errors`), and a submitted image over it is refused before the transcript keeps it.

History can still hold images over the limit: ones an earlier, looser provider accepted before a model switch, or ones from before limits were declared. At the start of each model step, before the request is prepared, the loop has `albedo-render --fit EDGE` scale each such image down (aspect kept, Lanczos; a JPEG stays JPEG, anything else becomes PNG) and appends an image fit row to the transcript (`transcript.ImageFit`): the copy, stored in `images` like any payload, the original's payload hash, and a user note from origin `image scaled` (`An earlier image was scaled from WxH to WxH to fit this model's EDGEpx edge limit; the transcript keeps the original.`). Loading the history applies each fit to every row before it, so the transcript alone says what any request carried: provider request rows, `/context`, forks, and restarts all see the copy, and a fork from before the fit row starts from the original. Readers that only show rows see the fit as its note, which the chat shows once. The original row is never rewritten. A fit is permanent: switching back to a looser provider keeps the copy (fitting per edge is a TODO in `daemon/image_fit.gleam`). Snapcompact frames never need fitting, because they are rendered to fit. Without `albedo-render` the turn fails before sending, naming the binary, rather than getting the provider's 400.
