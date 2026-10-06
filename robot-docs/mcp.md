# MCP extension

Persisted preferences are owned by the daemon and changed through the [settings API](settings.md). The CLI refreshes them on use and never writes settings files.


Albedo's `mcp` extension connects one session to configured [Model Context Protocol](https://modelcontextprotocol.io) servers and advertises their discovered tools, resources, and prompts as ordinary model tools. It is installed but disabled by default: enable it from `/extensions`, for every session or (after `s`) just the current one.

The client is [`barrel_mcp`](https://hex.pm/packages/barrel_mcp), so stdio and streamable HTTP transports, protocol negotiation, pagination, and cancellation come from a maintained MCP implementation. Albedo owns configuration, credential scope, naming, and lifecycle.

## Add servers from albedo

`/mcp` lists configured servers. `n` opens one form for a new server:

- **transport**: `http` (default) or `stdio`, switched with ← →.
- **url** for HTTP, or **command** for stdio, written as you would type it in a shell (`npx -y @modelcontextprotocol/server-filesystem "/srv/my docs"`); quotes are honoured but no shell runs.
- **name**, suggested from the URL host or the command's package until you edit it.
- **bearer token** and one custom **header** for HTTP, or `KEY=value` **env** entries for stdio. These are optional, masked while typed, and stored by the daemon in `creds.json` (mode 0600), never in `extensions.json`.

Nothing is written until the form is saved with ctrl+s (or enter on its last field). The server and its credentials are saved together and the session reloads once; if the server cannot connect, both are restored and the form stays open with the error. `enter` edits a server in the same form (a blank secret keeps the stored one, `-` removes it), `d` deletes a server and its credentials, and `e` re-enables a server switched off with `"enabled": false`.

## Configure servers

Servers live in the `mcp` section of `$ALBEDO_HOME/extensions.json` (default `~/.albedo/extensions.json`), never in `config.json` with provider credentials.

```json
{
  "mcp": {
    "servers": {
      "docs": {
        "type": "stdio",
        "command": "/usr/local/bin/docs-mcp",
        "args": ["--root", "/srv/docs"],
        "cwd": "/srv/docs",
        "env": { "DOCS_TOKEN": { "env": "MY_DOCS_TOKEN" } }
      },
      "search": {
        "type": "http",
        "url": "https://mcp.example.com/mcp",
        "bearerTokenEnvVar": "MY_SEARCH_TOKEN",
        "enabledTools": ["search"],
        "callTimeoutMs": 30000
      }
    }
  }
}
```

Secrets are named, never inlined: every `env` value and HTTP header reads one process environment variable of the daemon, and a missing variable fails preparation instead of connecting without it. `enabled`, `enabledTools`, `disabledTools`, `startupTimeoutMs`, and `callTimeoutMs` are optional.

A stdio server is launched as an exact executable and argument vector through Albedo's own launcher, with no shell, a scoped working directory, discarded server stderr, and an environment reduced to `HOME`, `PATH`, `TMPDIR`, and the values you named. HTTP servers may use `https` or `http`, including trusted LAN and tailnet addresses. Plain HTTP provides no transport encryption by itself: use it only on a network you trust (a tailnet encrypts its own traffic). Credentials are sent to the configured endpoint, so verify its address before adding auth. URLs carrying userinfo or a fragment are rejected.

## Tools and lifecycle

Discovered capabilities are advertised as `mcp_<server>_<operation>_<hash>`, so two servers that expose the same tool name stay distinct and stable. Resources and prompts, when a server offers them, appear as one `read_resource` and one `get_prompt` operation per server. Connections belong to the session composition: enabling, disabling, or reloading the extension prepares a replacement first and closes the previous connections only after a successful swap.

### Saved catalogues

Preparation runs in the daemon-wide runtime actor (see [extensions](extensions.md)), so it never waits on a server it has heard from before. Each discovery is saved in the `mcp_catalogues` table, one row per server name, under a fingerprint of that server's configuration and credentials. A session opening with a saved catalogue for the current fingerprint advertises those tools and context at once and dials the server in the background. A tool call that arrives first waits for that dial, up to `startupTimeoutMs` plus `callTimeoutMs`. If the background discovery matches the saved catalogue, nothing else happens: no note, no new prompt. If it differs, the new catalogue is saved and the session refreshes after its next turn, the same way a returning server does.

A server with no saved catalogue (never connected, or its configuration or credentials changed) is connected and discovered during preparation, so only the first session after a change waits on it.

A server that cannot start, initialize, or be discovered during that first connection is left out of the session and named in a warning; the servers that did connect load as usual. A server with a saved catalogue that turns out unreachable stays advertised: its calls report it unavailable, and each later call dials it again. A client that drops after connecting, or that a timed-out call closed, is dialled again by the next call. Bad configuration (an invalid name, a missing credential file, a catalogue over the size limit) still fails the whole preparation, and the session keeps its previous working composition. Disabling the extension closes every connection and terminates each stdio subprocess.

### Servers that come back

A server that was left out joins the session once it connects, the way a skill does after a reload: albedo prepares the extension again, appends a "capabilities changed" user turn, and keeps the cached system prompt until compaction.

There is no timer. The extension probes the missing servers when the session shows activity (a submit or the end of a turn), first `retryMs` after the session prepared and then at doubling intervals, capped at twenty times `retryMs`. A server found up waits for the end of a turn and then asks the session to refresh, so it appears after the turn that follows its return, not mid-turn. `retryMs` (default `30000`) sits beside `servers` in the `mcp` section.

### Saving a server

The `/mcp` form and the capability toggle stay strict: saving or turning on a server that cannot start is refused (409) and the previous settings and credentials are restored, so a mistyped command is caught where it is typed. A server that is switched off, or off for the session by a capability choice, is not tried.

Tool calls may have side effects, so a failed or interrupted call is never retried automatically. Transport loss is reported as an unknown outcome, which the model must inspect before acting again.

## From Python

With the extension enabled, `await mcp.tools()` lists live operations and `await mcp.describe(name)` returns one operation and its parameter schema. `await mcp.call(name, arguments=None, **kwargs)` accepts an advertised name or `server/tool`; methods minted at kernel boot are also available as `await mcp.<server>.<tool>(**arguments)`. Results are records: check `r.isError`, because a tool-reported error does not raise. MCP responses are untrusted data; use `await asyncio.gather(..., return_exceptions=True)` to keep successful results when one call fails.

Remote servers are untrusted input. Tool descriptions, resource contents, and prompt text are data, not instructions, and their schemas are bounded before they reach the model.
