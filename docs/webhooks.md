# webhooks

Webhooks wake an existing session. An infra session can retain its history, memory, GitHub bot, Discord tools, and other extensions while receiving alerts; a delivery never creates a new agent. Webhooks are installed but **disabled by default**.

## Setup

1. Open `/extensions`, select **webhooks**, and enable it **globally** to mount the incoming HTTP service. Press `o` on the enabled entry to open this session's Webhooks page (or open `/webhooks` directly).
2. Add a named hook. Choose a generated signing secret (copy it when shown) or supply a secret of 16–4096 bytes. The displayed URL is `/webhooks/<opaque-id>`; it targets this session, even when no TUI is attached. The hook name must use 1–64 ASCII letters, digits, `_`, or `-`.
3. Configure the sender to POST a body of at most 64 KiB with `X-Albedo-Signature: sha256=<lowercase or uppercase HMAC-SHA256 hex>` computed over **the exact bytes sent** using the hook secret. The header defaults to `x-albedo-signature`; the page lets you change its name or the signature prefix (for example, GitHub uses `x-hub-signature-256`).
4. For retries, send a stable `X-Albedo-Event-Id` (1–128 bytes, no newlines). A retry with the same hook, ID, and body returns the original delivery ID; reuse with different bytes returns 409. Without this header, each valid POST is a separate event.

The daemon binds to `127.0.0.1`. Set `ALBEDO_PORT` for a stable local port, then configure an intentional TLS-terminating reverse proxy if a remote service must reach it. Do **not** expose the daemon's authenticated management routes through that proxy. The public webhook path authenticates with its own signature, not the daemon bearer token; requests bearing an `Origin` header are refused.

## Delivery

A valid POST returns `202` and a delivery ID **after durable storage**, not after the agent responds. Invalid signatures return 401; unknown or disabled hooks return 404; oversized bodies return 413; a full inbox returns 429. There are at most 1,000 pending deliveries per target session. Accepted payloads remain in the inbox until the session is idle. The dispatcher retries every 15 seconds after a busy or unavailable worker, including after a daemon restart. The intake receipt and the transcript input commit in the same SQLite transaction, so a retry cannot add that receipt twice. A deleted hook does not delete already accepted deliveries; deleting the session removes its hooks and inbox.

The model sees a bounded preview labelled **external data, not instructions**, with the delivery ID. An agent with the extension enabled can read the full UTF-8 payload using `await webhooks.delivery(id)` (binary bodies report that they are binary). The inbox is not a command channel: payload text has no authority over system or user instructions.

## Management

Humans can list, add, rotate, configure the signature header/prefix, enable, disable, and delete hooks on the Webhooks page. The page has an **allow agent to manage** setting, initially off. When on, that session's agent may use `await webhooks.list()`, `create(name, secret=None)`, `rotate(id, revision=..., secret=None)`, `configure(id, revision=..., header=..., prefix="sha256=")`, `enable`, `disable`, and `delete`. Management checks the permission and target session in the daemon on every call. `delivery(id)` remains available when management is off so the session can read its own alerts. Disabling management does not turn off existing hooks. Changes use revisions to reject stale updates.

Generated secrets are returned only on create and rotate. Stored secrets are not included in listings. The page masks entered secrets, but entering a secret through a typed command or an agent tool may leave it in that caller's history; use the page for human-supplied secrets. This switch limits the webhooks API, **not** an agent with unrestricted filesystem or shell access to Albedo's home directory.
