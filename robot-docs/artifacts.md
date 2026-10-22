# artifacts

An **artifact** is a web page the agent made: one HTML file, a few files, or a whole built app. It opens in a window beside the chat that made it (web), or in the browser from a row in the transcript (terminal). Every version is kept, and artifacts outlive their session: deleting a session leaves its artifacts in the gallery, which is the only place an artifact is deleted.

The `artifacts` extension (`src/albedo/harness/extensions/artifacts/`, enabled by default) owns the storage, the Python module, the HTTP service and the page bridge. Clients draw it: `web/` has the window and the gallery, `cli/internal/tui` the row, and `albedo web` (`cli/internal/webui`) serves the pages.

## the model's side

The Python module `artifacts`:

- `artifacts.create(title, html=None, *, files=None, directory=None, entry="index.html")` makes an artifact at version 1. Give exactly one source: `html` (the entry file's text), `files` (a dict of relative path to `str` or `bytes`), or `directory` (a folder to publish whole, such as a build's `dist`).
- `artifacts.update(id, html=None, *, files=None, directory=None, entry=None, title=None)` writes the next version. `html` replaces the entry file and keeps the rest; `files` changes only the paths it names (a value of `None` removes that path); `directory` replaces the whole tree; with no source it only renames.
- `artifacts.list(limit=20, session=None)` lists artifacts, newest change first; `session="current"` keeps this session's.
- `artifacts.get(id, version=None)` describes one version: `id`, `title`, `version`, `versions`, `entry`, `files` (path to size), `session`, `created_at`, `updated_at`.
- `artifacts.read(id, path=None, version=None)` returns one file (the entry by default), `str` for text, `bytes` otherwise.
- `artifacts.state(id)` is what the page saved through `localStorage`; `artifacts.errors(id)` is what failed in the page (newest last, at most 20).
- `artifacts.url(id, version=None)` is the page's address on the running `albedo web`, for checking it with the browser plugin.

Each `create` and `update` adds an `artifact` activity to the running cell's trace: `{"kind": "artifact", "target": <title>, "artifact": {"id": <id>, "version": <n>}}`. That is how both clients learn of it, from history they already read; the trace holds no capability key.

Uploads are content addressed: the module hashes each file (SHA-256), asks the daemon which it lacks (`artifacts.missing`), sends only those (`artifacts.upload`, one file per call, base64), then saves the version as a manifest of path, hash and size (`artifacts.save`). Publishing an app again sends only the files that changed.

Limits: 16 MiB per file, 64 MiB and 2,000 files per version. A path is relative, uses `/`, has no empty, `.` or `..` segment, does not start with `.albedo/`, and is at most 512 bytes. Titles are 1 to 200 characters.

## storage

| table | holds |
| --- | --- |
| `artifacts` | `id`, `key` (the capability, 32 hex characters), `session`, `workspace`, `title`, `version` (latest), `created_at`, `updated_at` (ms) |
| `artifact_versions` | `artifact`, `version`, `entry`, `manifest` (JSON: path to `{hash, size}`), `cell`, `created_at` |
| `artifact_files` | `hash` (SHA-256 hex), `size`, `data` |
| `artifact_state` | `artifact`, `state` (JSON object of string to string), `updated_at` |
| `artifact_errors` | `artifact`, `version`, `at`, `message`, `source`, `line`, `column`, `stack` |

Nothing is deleted with its session. Deleting an artifact removes its rows and every file no remaining version names.

## HTTP

Under `/extensions/artifacts/`, all with the daemon token:

- `GET items?limit=&next=&session=` — the gallery, newest change first: `{items: [Artifact], next}`. An `Artifact` is `{id, key, title, version, versions, entry, session_id, session_name, session_deleted, workspace, created_at, updated_at, bytes}`.
- `GET items/{id}` — one artifact with `history`: `[{version, entry, created_at, cell_id, files: [{path, size}], bytes}]`, newest first.
- `DELETE items/{id}` — `204`.
- `GET frame/{id}.{key}/{version}/{path}` — one file of one version, with its content type. An HTML file gets the bridge (below) injected first thing in its `<head>`. A wrong key is `404`, as is a missing path; a path ending in `/` serves its `index.html`.
- `POST frame/{id}.{key}/{version}/.albedo/state` — the page's `localStorage`, a JSON object of string to string, at most 1 MiB; `204`.
- `POST frame/{id}.{key}/{version}/.albedo/errors` — one failure, `{message, source, line, column, stack}`, at most 16 KiB; `204`.

The frame routes are what `albedo web` forwards; a browser never reaches the daemon itself.

## albedo web

`/frame/...` forwards to the daemon's `/extensions/artifacts/frame/...` with the token and without the cookie, `Origin` or `Referer`. It needs no sign-in: the key in the path is the capability. Only `GET` and `HEAD`, and `POST` to the two `.albedo/` paths, pass. Every answer carries

```
Content-Security-Policy: sandbox allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads allow-pointer-lock
Access-Control-Allow-Origin: *
Cross-Origin-Resource-Policy: cross-origin
Referrer-Policy: no-referrer
X-Content-Type-Options: nosniff
```

so a page opened in its own tab is sandboxed exactly as one in a window.

While it runs, `albedo web` keeps `$ALBEDO_HOME/web.json`: `{"pid", "port", "url"}`, where `url` is its loopback base (`http://127.0.0.1:4317`). It removes the file when it stops.

## the boundary

A page has the network: it can load libraries from a CDN, call APIs and open websockets, as the kernel already can. What it must never reach is albedo: the daemon's API, the web client's cookie or page, the browser storage of albedo's origin. Both the window's `<iframe sandbox>` (without `allow-same-origin`) and the CSP `sandbox` header give the page an opaque origin, so:

- its requests to `/api` carry `Origin: null`, which the proxy refuses, and no cookie (they are cross-site, and the cookie is `SameSite=Strict`);
- `parent.document`, `document.cookie`, `localStorage` and `sessionStorage` throw, until the bridge stands in for the last three;
- it cannot navigate the window that holds it.

Measured in Chrome on 2026-10-21 with a throwaway server shaped like this one: the frame's own document request carries the cookie (it is same-site), every request from inside the page carries neither cookie nor origin, a module script needs the `Access-Control-Allow-Origin: *` above, and `Object.defineProperty(window, "localStorage", ...)` replaces the throwing getter.

## the bridge

The daemon injects `priv/artifacts/bridge.js` into every HTML file it serves, with `window.__albedo = {id, version, title, base, state}` before it (`base` is the version's frame path ending in `/`; `state` the saved storage). Pages use plain web APIs and, if they want to talk, `window.albedo`.

- **Storage.** `localStorage` is an in-memory store seeded with the saved state; each change is saved (`POST .albedo/state`, debounced 400 ms, and on `pagehide`). `sessionStorage` and `document.cookie` are in-memory stand-ins. State is per artifact, so it carries across versions and reloads.
- **Errors.** `error` and `unhandledrejection` are sent to `POST .albedo/errors` (at most 20 per load) and posted to the window as `albedo/error`.
- **Theme.** `:root` gets albedo's colours as CSS variables, from the window when it says (`ui/notifications/host-context-changed`), else from `prefers-color-scheme`: `--albedo-bg`, `--albedo-surface`, `--albedo-text`, `--albedo-muted`, `--albedo-faint`, `--albedo-accent`, `--albedo-border`, `--albedo-added`, `--albedo-danger`, `--albedo-sans`, `--albedo-mono`, plus `color-scheme` and `data-albedo-theme` (`light` or `dark`).
- **Messages.** `albedo.send(text)` asks the window to post `text` to the chat as you, and resolves to `{sent: true}` or `{sent: false, reason}` (no window, or held by the loop guard). In a tab of its own there is no chat to post to.
- **Size.** Its document's height is posted as `ui/notifications/size-changed`, for the phone, which fits an artifact to its content.
- **Notes.** A canvas note can be tied to a part of the page. While a note's tie is drawn over the page, the window posts `albedo/point` `{x, y}` (page pixels) and the page answers `albedo/pointed` with the part under it: the nearest heading, paragraph, list item, control, media, table cell, landmark or element with an id or role, as a CSS selector (an `#id` where one is unique, else `tag:nth-of-type(n)` steps from `body`), a quote (its text, alt or value, at most 600 characters) and its rect. For tied notes the window posts `albedo/watch` `{selectors}` (at most 64; sent again when the page loads again), and the page reports `albedo/rects` `{rects: {selector: rect or null}}` at once and after every scroll, resize or DOM change, a frame at most.

The page and the window speak JSON-RPC 2.0 over `postMessage`, a subset of [MCP Apps](https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx), so a page written for it mostly works here:

| from the page | the window |
| --- | --- |
| `ui/initialize` (request) | answers `{protocolVersion: "2026-01-26", hostInfo: {name: "albedo"}, hostCapabilities: {message: {}}, hostContext: {theme, styles: {variables}, displayMode: "inline"}}` |
| `ui/notifications/initialized` | nothing |
| `ui/message` (request; `params: {role: "user", content: [{type: "text", text}]}`, plus albedo's `gesture`: whether the person had just clicked or typed in the page) | posts the text to the chat, headed `From the artifact “<title>” (v<n>):`, and answers `{}`; or answers an error when held |
| `ui/notifications/size-changed` | sizes the phone's inline view |
| `albedo/error` | marks the window's title bar and lists the failure under the page |
| `albedo/wheel` (a pinch or ctrl-wheel over the page) | replays it on the frame, so it zooms the canvas |
| `albedo/pointed`, `albedo/rects` (answers to the window's `albedo/point` and `albedo/watch`) | outlines the part a tie would land on; draws the line and tint to each tied part |
| `tools/call` and anything else | an error: pages cannot reach the agent's tools |

**The loop guard.** A message sent with a gesture always goes; the bridge counts one click or key press for one message, since a timer a click started still runs inside the browser's activation window. Without one (a timer, a render loop), a page may send five a minute; past that the window holds them behind a button that says how many are waiting. It guards against a buggy page starting turn after turn, never against a person using one.

## clients

**Web.** A new artifact activity in a chat on the board opens a window beside that chat, tied to it like a review; only activities that arrive while the chat is open do this, never ones loaded from history. A window for an artifact that is already open moves to the new version in place. The view pans to it only when its chat is the selected window. A closed window stays closed; the chat's row says it changed and opens it. A window can be pinned to a version, and then it stays there. On a phone the artifact opens inside the chat, as a review does. A page icon in the chat's title bar (on the phone, above the composer; `ArtifactsButton.svelte`) counts the artifacts the session made and lists them, newest change first, to open one; the list is read when it opens and when the session's work stops. The palette finds artifacts by title; `open an artifact…` and `delete an artifact…` list the whole gallery.

**Terminal.** An `artifact` activity is the row `↗ open artifact albedo made for you: <title>` (`… albedo updated: <title> · v<n>` after the first version), under its burst whether the burst is open or not. A click opens the page in the browser: the TUI reads the artifact's key from `GET items/{id}`, finds `albedo web` through `web.json` (starting `albedo web --no-open` when it is not running) and opens `<url>/frame/{id}.{key}/{version}/{entry}`.
