# models catalog

The `models` extension keeps a local copy of the [models.dev](https://models.dev) catalog and answers one question for the rest of Albedo: what is actually known about this model and its provider. It never guesses a limit from a model name.

It is enabled by default and contributes no model tools and no prompt context.

## cache

The catalog is cached at `$ALBEDO_HOME/models.json` (default `~/.albedo/models.json`). Albedo refreshes it when it is missing or older than the refresh window, in the background, and writes it by rename so a partial download is never readable. A failed fetch keeps the previous cache, and the whole file stays as models.dev published it.

```json
{ "models": { "url": "https://models.dev/api.json", "refreshHours": 24 } }
```

Put this in `$ALBEDO_HOME/extensions.json`. `refreshHours: 0` disables automatic fetching and uses only the cached file, which is what the test suite and air-gapped hosts do. Only `https`, or `http` on the loopback host, is fetched.

Run `/reload models` to fetch the configured catalog immediately, regardless of its age or `refreshHours`. The command returns only after the cache has been atomically replaced, so the next `/model` picker reads the new model list. A failed fetch leaves the previous cache in place and reports the failure.

## lookup

A lookup takes the session's model id and its configured provider base url. The endpoint decides between providers that publish the same model id. Without a host match, candidates that agree still answer, and candidates that disagree stay unknown rather than picking one. Both the catalog key and its trailing segment resolve, so `vendor/model` and `model` find the same entry.

An answer carries the context window, the maximum output, the input modalities, the provider id, its documented API endpoint, and its expected environment variable names. Everything is reported with its source: the cached file and how the model was matched.

## used by

`rolling` compaction asks for the context window when `contextWindowTokens` is not configured, so compaction works without hand-configuring each model. An explicit setting still wins. `/context` shows the window and names where it came from; an unlisted model stays explicitly unknown.

Provider extensions consume the catalog's endpoint and environment metadata, so authentication and transport policy do not require the daemon to hardcode a model list.

## provider extensions

The catalog also lists model ids by provider or endpoint. `/login` and `/model` read those lists only from this cache; they never call a provider's `/models` endpoint. The `openai` model-provider extension depends on `models` and owns API-key configuration plus the shared Responses/Chat Completions client. The `codex` extension depends on `openai`; it reuses that request stack and adds only ChatGPT OAuth, account selection, and Codex wire policy. The dependency chain is therefore `codex -> openai -> models`. Codex filters its subscription picker to catalogued GPT-5.6 and GPT-6 series, without restricting the generic OpenAI picker. `antigravity` has no dependencies: it brings its own catalog and sign-in, and its upstream drives `openai_api.exchange` with its own encoder and reducer. `claude` depends on `models`: it selects its current and fallback models from the cached Anthropic namespace, reads exact provider-scoped limits and efforts, and uses a Messages transport with Claude Code OAuth rather than the catalog's API-key credentials.

Saved provider profiles carry an `extension` tag. Existing profiles without one migrate as `openai`. Codex profiles use `extension: "codex"` and keep OAuth credentials separately in `$ALBEDO_HOME/auth.json`; see [model authentication](auth.md).

Codex metadata lookups select the `openai` provider in models.dev explicitly, including its reasoning effort tiers and context limits. `/effort`, session defaults, and model switches use this same selection; another provider publishing the same model id cannot replace OpenAI's metadata. No authenticated Codex model catalog is fetched.

## antigravity models

Antigravity is not on models.dev, and its model ids and required `model_enum` labels change server-side. The `antigravity` extension therefore contributes its own catalog. It asks Cloud Code Assist `fetchAvailableModels` which models the account can use, keeps the ids that the real client's agent picker shows, and caches them with their limits, labels, and the renames of retired ids in `$ALBEDO_HOME/antigravity.json`. The cache refreshes in the background after 6 hours, and the first `/login` listing waits for discovery. A built-in table supplies each model's thinking control and serves as the list before the first discovery. A saved profile that names a retired id follows the backend's rename. The catalog answers lookups only for the Antigravity endpoint, so models.dev keeps answering for the same ids at other providers.

## contribute another catalog

`extension.ModelsPlugin(ModelCatalog(lookup, list))` is the catalog contract. `lookup(model, endpoint)` returns facts for one model; `list(provider, endpoint)` returns ids owned by one catalog provider. The first enabled catalog with an answer wins, so a private or offline catalog can be installed ahead of models.dev.

A model transport contributes `ModelProviderPlugin(ModelProvider(catalog_provider, resolve))`. `catalog_provider` is the models.dev namespace used by `/login` and `/model`; `resolve` returns the profile's `extension.Upstream`: its endpoint, the replay protocol it produces, a `stream` function over albedo's request types, and `explain`, which turns a provider failure into an actionable message. `openai` builds upstreams from the shared `openai_api` client with `openai.upstream`; a provider with another wire format supplies its own `stream`. Its extension should require the catalog or transport extension whose metadata and wire behavior it reuses. For example, `openai` declares the `openai` namespace, while `codex` also declares `openai` and inherits the shared transport through its dependency. New provider extensions get catalog-backed discovery by declaring their namespace; they do not implement provider `/models` calls.
