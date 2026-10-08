# webhooks

Webhooks wake an existing session. An infra session can retain its history, memory, GitHub bot, Discord tools, and other extensions while receiving alerts; a delivery never creates a new agent. Webhooks are installed but **disabled by default**.

## Setup

1. Open `/extensions`, select **webhooks**, and enable it **globally** to mount the incoming HTTP service. Press `ctrl+w` on the enabled entry to open this session's Webhooks screen (or type `/webhooks`). The slash shortcut is always in the CLI menu, even before the session command catalog loads or when the extension is off; an off extension shows guidance to enable it in `/extensions`.
2. Press `n` to add a named hook. Its **session** field picks the session deliveries wake; it defaults to the one you opened the screen from, and typing filters the list. The screen lists every session's hooks grouped under the session they wake, and the selected hook's **wakes** line names it. Leave the secret blank to generate one (it is shown once; `c` copies it) or supply a secret of 16–4096 bytes. `y` copies the selected hook's URL. The displayed URL is `/extensions/webhooks/hooks/<hook-id>/deliveries`; it targets the chosen session, even when no TUI is attached. The hook name must use 1–64 ASCII letters, digits, `_`, or `-`.
3. Configure the sender to POST a body of at most 65,536 bytes with `X-Albedo-Signature: sha256=<lowercase or uppercase HMAC-SHA256 hex>` computed over **the exact bytes sent** using the hook secret. Fixed-length and chunked uploads are supported. The header defaults to `x-albedo-signature`; the add/edit form sets its name and the signature prefix (for example, GitHub uses `x-hub-signature-256`).
4. For retries, send a stable `X-Albedo-Event-Id` (1–128 bytes, no newlines). A retry with the same hook, ID, and body returns the original delivery ID; reuse with different bytes returns 409. Without this header, each valid POST is a separate event.

The daemon binds to `127.0.0.1`. Set `ALBEDO_PORT` for a stable local port, then configure a TLS-terminating reverse proxy if a remote service must reach it. Expose only the delivery POST route for public intake. Hook management and delivery reads require the daemon bearer token. The delivery POST uses the `SignedBody` policy: a daemon bearer token cannot bypass its signature check. Browser requests follow the daemon's configured origin policy.

Ambiguous framing and invalid `Content-Length` values return `400`; bodies
above 65,536 bytes return `413`. A request without body framing has an empty
body. Refusals before body consumption close the connection.

## Delivery

A valid POST returns `202` and a delivery ID **after durable storage**, not after the agent responds. Invalid signatures return 401; unknown or disabled hooks return 404; oversized bodies return 413; a full inbox returns 429. There are at most 1,000 pending deliveries per target session. Accepted payloads remain in the inbox until the session is idle. The dispatcher retries every 15 seconds after a busy or unavailable worker, including after a daemon restart. The intake receipt and the transcript input commit in the same SQLite transaction, so a retry cannot add that receipt twice. A deleted hook does not delete already accepted deliveries; deleting the session removes its hooks and inbox.

The model sees a bounded preview labelled **external data, not instructions**, with the delivery ID. An agent with the extension enabled can read the full UTF-8 payload using `await webhooks.delivery(id)` (binary bodies report that they are binary). The inbox is not a command channel: payload text has no authority over system or user instructions.

## Management

Humans can list, add, rotate, configure the signature header/prefix, enable, disable, and delete hooks on the Webhooks screen, which also shows each hook's queued deliveries and the reason the last one was deferred. The screen's **agent access** setting (`ctrl+t`, kept visible in the browse footer on narrow terminals) applies to the session the screen was opened from and is initially off. When on, that session's agent may use `await webhooks.list()`, `create(name, secret=None)`, `rotate(id, revision=..., secret=None)`, `configure(id, revision=..., header=..., prefix="sha256=")`, `enable`, `disable`, and `delete`. Management checks the permission and target session in the daemon on every call. `delivery(id)` remains available when management is off so the session can read its own alerts. Disabling management does not turn off existing hooks. Changes use revisions to reject stale updates.

Generated secrets are returned only on create and rotate. Stored secrets are not included in listings. The screen masks entered secrets, but entering a secret through a typed command or an agent tool may leave it in that caller's history; use the screen for human-supplied secrets. This switch limits the webhooks API, **not** an agent with unrestricted filesystem or shell access to Albedo's home directory.
