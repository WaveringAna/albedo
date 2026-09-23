# model authentication

model authentication is supplied by model-provider extensions rather than the daemon configuration loader.

## openai-compatible api keys

The enabled-by-default `openai` extension requires `models`. It handles existing named OpenAI-compatible profiles and both Responses and Chat Completions. Model discovery comes from the models.dev cache, not the configured API endpoint. Older `config.json` profiles without an `extension` field remain OpenAI profiles; newly saved profiles include `"extension": "openai"`.

## chatgpt codex oauth

The enabled-by-default `codex` extension requires `openai`, so it reuses the OpenAI Responses encoder, SSE transport, replay format, and model metadata. `/login` can add ChatGPT Plus/Pro accounts. A fresh install can enter `codex` as the provider name; an existing install can choose **add chatgpt codex account**.

The login follows the Codex CLI browser flow: PKCE S256, the allowlisted `http://localhost:1455/auth/callback`, state validation, and a manual callback-url/code input that races the local callback. The token exchange uses OpenAI's public Codex client id and stores access, rotating refresh, expiry, ChatGPT workspace id, seat id when present, and email when present.

Credentials live in `$ALBEDO_HOME/auth.json`, mode `0600`, under the `openai-codex` key. One account uses the legacy object shape; two or more use an array. A login replaces the same seat/account identity and appends a different account. `/login` lists saved providers and each stored account; `d` (or delete) on either row asks to remove it, and enter on an account does the same. Removing the active provider makes the first remaining provider by name active. A Codex provider with no accounts left reads `signed out` and starts a sign-in when chosen. Access tokens refresh under `auth.lock` 60 seconds before expiry, with a re-read under the lock so concurrent sessions do not overwrite a newer refresh.

Each session hashes its id into the account pool and stays on that account. If that account is invalid or cannot refresh, selection continues through its siblings. When the Codex backend answers a request with 401 (for example `token_revoked`), that account is removed from `auth.json` and the turn fails with an error ending in `run /login`; the TUI opens `/login` when that error follows a turn sent from the open chat. Requests use `https://chatgpt.com/backend-api/codex/responses` with Bearer auth, `chatgpt-account-id`, Codex experimental Responses headers, and the session request id. Codex request bodies force `store: false`, automatic parallel tools, low text verbosity, encrypted reasoning replay, and nullable tool strictness.

The oauth callback binds only to `127.0.0.1`. Port 1455 is fixed because OpenAI allowlists the exact redirect URI; a busy port fails instead of silently changing redirects.
