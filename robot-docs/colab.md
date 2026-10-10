# colab

the `colab` extension (requires `python` and `remote`) manages Google Colab
runtimes from the kernel and reaches one through `remote`.

- **sign-in**: `/login colab` stores a Google account under
  `accounts["google-colab"]` in creds.json (`access`, `refresh`, `expires`,
  `email`). the OAuth mechanics (code exchange, userinfo email, locked refresh)
  are `albedo_google_oauth.erl`'s, shared with antigravity; `albedo_colab_auth.erl`
  is the colab client and account choice: the selected account, else the first.
- **tokens stay in the daemon**: the kernel never reads creds.json. the
  `colab.account` host route (`extension.gleam`) answers `{access, email}` with
  the token refreshed and saved under the credential lock, or a refusal that
  `colab.py` raises as `ColabError`. every API call asks again, so a long
  session outlives the hour a token lives.
- **runtimes**: `colab.instances()`, `status()`, `launch()` and `stop()` call
  the `/tun/m/*` endpoints with the XSRF handshake. an instance is a
  `ColabInstance` record with `connect()` and `stop()` methods.
- **connect**: `colab.connect(vm)` takes a fresh listing (the runtime proxy token
  expires), registers an ssh alias `colab-<id>` and returns `remote.connect()`
  on it. the alias's `ProxyCommand` is `python -m albedo_plugins.ws`, which bridges
  stdio to `wss://<proxy>/colab/ssh`; the proxy url and the public key header
  reach it as `ALBEDO_WS_URL` and `ALBEDO_WS_HEADERS` in its environment. nothing is
  written to `~/.ssh/config`. a missing ssh public key (`~/.ssh/id_ed25519.pub`,
  `id_ecdsa.pub`, or `ssh_key=`) is an error before anything connects.
  `stop()` drops the alias; it does not close a connection already open on it.
- **tests**: `test/harness/colab_plugin_test.py` (the plugin against a faked
  HTTP layer), `ws_test.py` (frames, and the bridge in a real
  subprocess) and `google_oauth_test.gleam` (the refresh against a local token
  endpoint).
