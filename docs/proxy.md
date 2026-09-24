# proxy

The `proxy` extension serves an OpenAI-compatible Chat Completions endpoint for every saved provider profile, so other tools can use albedo's providers (Codex, Antigravity, OpenAI-compatible endpoints) through one base url. It is installed and disabled; enable it globally in `/extensions` or with `{"enabled": {"proxy": true}}` in `$ALBEDO_HOME/extensions.json`. The change applies to the next request.

## endpoint

The proxy is a [service](extensions.md) mounted at `http://127.0.0.1:<port>/proxy/v1`. Set `ALBEDO_PORT` in the daemon's environment to keep the port stable; otherwise it changes each time the daemon starts (see `$ALBEDO_HOME/daemon.json`).

- `GET /proxy/v1/models` lists `<profile>/<model>` for every usable profile in `config.json`. A profile with its own `baseUrl` (an API-key profile) lists only its saved model, because models.dev can only guess what an arbitrary endpoint serves. Other profiles, such as `codex` and `antigravity`, list their provider's catalog, or their saved model while no catalog is cached. Profiles that cannot be used, such as a malformed entry, are named under a nonstandard `errors` field (`[{"profile", "message"}]`) instead of failing the list.
- The list only helps clients choose. Any `<profile>/<model>` is requested as given, listed or not, and a broken or signed-out profile fails only its own requests.
- `POST /proxy/v1/chat/completions` accepts `model` as `<profile>/<model>`, or a bare `<profile>` for its saved model. Streaming (`stream`, `stream_options.include_usage`) and non-streaming replies are supported.

There is no API key: the daemon binds only to loopback, and any local process can already read `auth.json`. Put an authenticating reverse proxy in front of it if you need one. Requests with an `Origin` header are refused, so web pages cannot call it.

## translation

Each request is translated into albedo's request types and projected onto the profile's upstream, as a session's history is:

- Leading `system` and `developer` messages become the instructions. Later ones become user notes in place.
- `user` text and base64 `data:` images become user input. Image urls are not fetched.
- `assistant` messages with `tool_calls` become replayable tool calls. `tool` messages become their results.
- `tools`, `max_tokens`/`max_completion_tokens`, `temperature`, `top_p`, `stop`, `tool_choice`, `parallel_tool_calls`, `reasoning_effort` (or `reasoning.effort`), and `response_format` (`json_object` or `json_schema`) become albedo's generation options. Each provider applies what its wire can express:
  - OpenAI Chat Completions and Responses take all of them, except that Responses has no stop sequences.
  - Codex keeps its fixed sampling. Effort, tool choice, parallel calls, and format override its defaults (medium effort, automatic parallel tools).
  - Antigravity maps effort onto each model's thinking budget or level, and sampling, stop sequences, and format into `generationConfig`. Claude routes always run tools `VALIDATED`. On Gemini routes a forced tool choice is also restated as a final instruction, because Cloud Code Assist drops the tool mode there.

Text and reasoning stream as `delta.content` and `delta.reasoning_content`. Each tool call is sent whole, with its id, name, and arguments, when the turn ends. Errors from the provider arrive as an `error` chunk while streaming, or as a JSON error otherwise.

## state

The proxy stores nothing. Each request carries its conversation, and provider identity that should be stable across it, such as a Codex account or an Antigravity trajectory, is derived from the profile and the first user message.

Providers also return opaque state that they require back within a tool-calling turn: Codex's encrypted reasoning items, Gemini's thought signatures on function calls, and Claude's signed thinking. Clients echo only plain Chat Completions, but they always echo a tool call's id verbatim. So when a turn ends in tool calls, the proxy compresses that turn's native provider output, tags it with the profile that produced it, and appends it to the first call's id as `<id>__albedo__<state>`, using only `[A-Za-z0-9_-]`. When the history comes back, those turns become albedo transcript entries again and pass through the same projection a session uses. A request to the same profile replays them verbatim; a request to another profile gets the portable text and calls. Tool results are matched to the provider's own call ids. State larger than 256 KiB is not carried, and damaged state falls back to the portable history. Turns without tool calls carry no state, which the providers do not need after the next user message.
