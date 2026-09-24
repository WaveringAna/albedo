# proxy

The `proxy` extension serves an OpenAI-compatible Chat Completions endpoint for every saved provider profile, so other tools can use albedo's providers (Codex, Antigravity, OpenAI-compatible endpoints) through one base url. It is installed and disabled; enable it globally in `/extensions` or with `{"enabled": {"proxy": true}}` in `$ALBEDO_HOME/extensions.json`. The change applies to the next request.

## endpoint

The proxy is a [service](extensions.md) mounted at `http://127.0.0.1:<port>/proxy/v1`. Set `ALBEDO_PORT` in the daemon's environment to keep the port stable; otherwise it changes each time the daemon starts (see `$ALBEDO_HOME/daemon.json`).

- `GET /proxy/v1/models` lists `<profile>/<model>` for every profile in `config.json`: its saved model and the models its catalog lists.
- `POST /proxy/v1/chat/completions` accepts `model` as `<profile>/<model>`, or a bare `<profile>` for its saved model. Streaming (`stream`, `stream_options.include_usage`) and non-streaming replies are supported.

There is no API key: the daemon binds only to loopback, and any local process can already read `auth.json`. Put an authenticating reverse proxy in front of it if you need one. Requests with an `Origin` header are refused, so web pages cannot call it.

## translation

Each request is translated into albedo's request types and projected onto the profile's upstream, as a session's history is:

- Leading `system` and `developer` messages become the instructions. Later ones become user notes in place.
- `user` text and base64 `data:` images become user input. Image urls are not fetched.
- `assistant` messages with `tool_calls` become replayable tool calls. `tool` messages become their results.
- `tools` and `max_tokens`/`max_completion_tokens` are passed through. Sampling options, `tool_choice`, and response formats are ignored.

Text and reasoning stream as `delta.content` and `delta.reasoning_content`. Each tool call is sent whole, with its id, name, and arguments, when the turn ends. Errors from the provider arrive as an `error` chunk while streaming, or as a JSON error otherwise.

## state

The proxy is stateless. Provider identity that should be stable across a conversation, such as a Codex account or an Antigravity trajectory, is derived from the profile and the first user message. Clients send history back as plain Chat Completions, so opaque provider state from earlier turns is not replayed: Antigravity thought signatures, Claude thinking signatures, and Codex encrypted reasoning. Requests still succeed through the portable path, but the model does not see its earlier reasoning.
