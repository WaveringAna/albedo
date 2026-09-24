# model authentication

model authentication is supplied by model-provider extensions rather than the daemon configuration loader.

## openai-compatible api keys

The enabled-by-default `openai` extension requires `models`. It handles existing named OpenAI-compatible profiles and both Responses and Chat Completions. Model discovery comes from the models.dev cache, not the configured API endpoint. Older `config.json` profiles without an `extension` field remain OpenAI profiles; newly saved profiles include `"extension": "openai"`.

## chatgpt codex oauth

The enabled-by-default `codex` extension requires `openai`, so it reuses the OpenAI Responses encoder, SSE transport, replay format, and model metadata. `/login` can add ChatGPT Plus/Pro accounts. A fresh install can enter `codex` as the provider name; an existing install can choose **add chatgpt codex account**.

The daemon runs the login (see [sign-in api](#sign-in-api)) with the Codex CLI browser flow: PKCE S256, the allowlisted `http://localhost:1455/auth/callback`, state validation, and a manual callback-url/code input that races the local callback. The token exchange uses OpenAI's public Codex client id and stores access, rotating refresh, expiry, ChatGPT workspace id, seat id when present, and email when present.

Credentials live in `$ALBEDO_HOME/auth.json`, mode `0600`, under the `openai-codex` key. One account uses the legacy object shape; two or more use an array. A login replaces the same seat/account identity and appends a different account. `/login` lists saved providers and each stored account; `d` (or delete) on either row asks to remove it, and enter on an account does the same. Removing the active provider makes the first remaining provider by name active. A Codex provider with no accounts left reads `signed out` and starts a sign-in when chosen. Access tokens refresh under `auth.lock` 60 seconds before expiry, with a re-read under the lock so concurrent sessions do not overwrite a newer refresh.

Each session hashes its id into the account pool and stays on that account. If that account is invalid or cannot refresh, selection continues through its siblings. When the Codex backend answers a request with 401 (for example `token_revoked`), that account is removed from `auth.json` and the turn fails with an error ending in `run /login`; the TUI opens `/login` when that error follows a turn sent from the open chat. Requests use `https://chatgpt.com/backend-api/codex/responses` with Bearer auth, `chatgpt-account-id`, Codex experimental Responses headers, and the session request id. Codex request bodies force `store: false`, automatic parallel tools, low text verbosity, encrypted reasoning replay, and nullable tool strictness.

The oauth callback binds only to `127.0.0.1`. Port 1455 is fixed because OpenAI allowlists the exact redirect URI; a busy port fails instead of silently changing redirects.

## sign-in api

Browser sign-ins run in the daemon, so every client shares one OAuth implementation. An extension contributes `extension.LoginPlugin(oauth.Login(...))`: the profile extension it serves, a chooser label and detail, the protocol its profiles use, its auth.json key, its loopback callback (host, port, path, and whether the port is fixed), and three functions. `authorize` builds the provider url from a `Grant` (redirect, state, PKCE verifier and challenge). `exchange` trades the code for the credential object to store and may report progress. `account` names a stored credential; equal ids are the same account. `albedo_oauth` owns the rest: the callback listener, the race with a pasted code, a 5-minute timeout, and locked writes. A sign-in replaces the stored account with the same id and appends a new one. One account is stored as an object, two or more as an array.

Clients use these daemon routes. All of them require the daemon token.

- `GET /auth` returns `{logins: [{provider, label, detail, protocol}], accounts: [{provider, id, label, detail, selected}]}`. Accounts whose labels collide get the start of their id appended.
- `POST /auth/{provider}` starts a sign-in and returns `201 {id, url}`. The client opens `url` in a browser unless `ALBEDO_NO_BROWSER` is set, and shows it for copying.
- `GET /auth/logins/{id}` returns `{state, message}`. `state` is `waiting`, `exchanging`, `done`, or `failed`; `message` is progress, the new account's label when done, or the failure reason. Clients poll it. A settled sign-in is forgotten after 10 minutes.
- `POST /auth/logins/{id}` with `{input}` delivers a pasted callback url, `code#state`, query string, or bare code.
- `DELETE /auth/logins/{id}` cancels the sign-in and closes its callback listener.
- `POST /auth/{provider}/accounts/{id}` selects that account; `DELETE` on the same path removes it.

After a sign-in finishes, the client lists models with `GET /models/{provider}` and saves the profile `{extension: provider, model, protocol}` itself. Profiles stay client-owned; credentials are daemon-owned.
