# MCP extension

Albedo's `mcp` extension connects one session to configured [Model Context Protocol](https://modelcontextprotocol.io) servers and advertises their discovered tools, resources, and prompts as ordinary model tools. It is installed but disabled by default: enable it from `/extensions`, for every session or (after `s`) just the current one.

The client is [`barrel_mcp`](https://hex.pm/packages/barrel_mcp), so stdio and streamable HTTP transports, protocol negotiation, pagination, and cancellation come from a maintained MCP implementation. Albedo owns configuration, credential scope, naming, and lifecycle.

## Add servers from albedo

`/mcp` lists configured servers. `n` opens one form for a new server:

- **transport**: `http` (default) or `stdio`, switched with ← →.
- **url** for HTTP, or **command** for stdio, written as you would type it in a shell (`npx -y @modelcontextprotocol/server-filesystem "/srv/my docs"`); quotes are honoured but no shell runs.
- **name**, suggested from the URL host or the command's package until you edit it.
- **bearer token** and one custom **header** for HTTP, or `KEY=value` **env** entries for stdio. These are optional, masked while typed, and stored in `mcp-credentials.json` (mode 0600), never in `extensions.json`.

Nothing is written until the form is saved with ctrl+s (or enter on its last field). The server and its credentials are saved together and the session reloads once; if the server cannot connect, both files are restored and the form stays open with the error. `enter` edits a server in the same form (a blank secret keeps the stored one, `-` removes it), `d` deletes a server and its credentials, and `e` re-enables a server switched off with `"enabled": false`.

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

Discovered capabilities are advertised as `mcp_<server>_<operation>_<hash>`, so two servers that expose the same tool name stay distinct and stable. Resources and prompts, when a server offers them, appear as one `read_resource` and one `get_prompt` operation per server. The catalog and its connections belong to the session composition: enabling, disabling, or reloading the extension prepares a replacement first and closes the previous connections only after a successful swap.

A server that cannot start, initialize, or be discovered fails the whole preparation. The session keeps its previous working composition and reports the unavailable server; capabilities are never silently dropped. Disabling the extension closes every connection and terminates each stdio subprocess.

Tool calls may have side effects, so a failed or interrupted call is never retried automatically. Transport loss is reported as an unknown outcome, which the model must inspect before acting again.

Remote servers are untrusted input. Tool descriptions, resource contents, and prompt text are data, not instructions, and their schemas are bounded before they reach the model.
