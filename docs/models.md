# models catalog

The `models` extension keeps a local copy of the [models.dev](https://models.dev) catalog and answers one question for the rest of Albedo: what is actually known about this model and its provider. It never guesses a limit from a model name.

It is enabled by default and contributes no model tools and no prompt context.

## cache

The catalog is cached at `$ALBEDO_HOME/models.json` (default `~/.albedo/models.json`). Albedo refreshes it when it is missing or older than the refresh window, in the background, and writes it by rename so a partial download is never readable. A failed fetch keeps the previous cache, and the whole file stays as models.dev published it.

```json
{ "models": { "url": "https://models.dev/api.json", "refreshHours": 24 } }
```

Put this in `$ALBEDO_HOME/extensions.json`. `refreshHours: 0` disables fetching entirely and uses only the cached file, which is what the test suite and air-gapped hosts do. Only `https`, or `http` on the loopback host, is fetched.

## lookup

A lookup takes the session's model id and its configured provider base url. The endpoint decides between providers that publish the same model id. Without a host match, candidates that agree still answer, and candidates that disagree stay unknown rather than picking one. Both the catalog key and its trailing segment resolve, so `vendor/model` and `model` find the same entry.

An answer carries the context window, the maximum output, the input modalities, the provider id, its documented API endpoint, and its expected environment variable names. Everything is reported with its source: the cached file and how the model was matched.

## used by

`rolling` compaction asks for the context window when `contextWindowTokens` is not configured, so compaction works without hand-configuring each model. An explicit setting still wins. `/context` shows the window and names where it came from; an unlisted model stays explicitly unknown.

The provider endpoint and environment names are the hook for provider authentication work: a future auth extension can describe a provider without Albedo hardcoding a list of vendors.

## contribute another catalog

`extension.ModelsPlugin(lookup: fn(model, endpoint) -> Option(ModelInfo))` is the plugin contract. The first enabled catalog that knows a model answers, so a private or offline catalog can be installed ahead of the models.dev one.
