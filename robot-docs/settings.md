# Persisted settings

The daemon owns global settings and each session's configuration, preferences, and selection overrides. Clients keep form drafts and connection information. The [protocol 3 design](../docs/http-api-design.md) and [OpenAPI contract](../docs/openapi.yaml) describe the HTTP resources.

## HTTP resources

Core requests use the daemon bearer token. The boundary checks host and origin before reading the body. JSON errors use `application/problem+json` with `status`, `code`, and `detail`.

| Resource | Read | Change |
| --- | --- | --- |
| Global settings | `GET /settings` or `GET /settings?group=<group>` | `PATCH /settings?group=<group>` with the group's `If-Match` validator |
| Session configuration | `GET /sessions/<id>?view=configuration` | `PATCH /sessions/<id>?view=configuration` with `If-Match` |
| Catalog | `GET /sessions/<id>/catalog` | Selection edits belong to session configuration or global capabilities settings |
| Deliberate opening | The summary includes `preferences.opens` | `PUT /sessions/<id>/visits/<visit-id>` counts one client-generated UUIDv7 once |
| Composition | The session includes desired and loaded revisions | `POST /sessions/<id>/reload` applies saved selection |

`PATCH` uses `application/merge-patch+json`. Omitted fields preserve values. Null clears an override or removes a map entry where the schema permits it. Duplicate keys and unknown fields are rejected.

The global groups are `providers`, `mcp`, `extensions`, `capabilities`, `models`, and `ui`. The unscoped read includes each group's resource URL and validator. A successful patch returns the saved group resource and application observations: desired revision, active service revision, `composition_changed`, validation, and warnings. `composition_changed` compares the composition revision (the `extensions`, `mcp`, and `capabilities` groups) before and after the save, so it is always false for the other groups. A patch never observes sessions; that costs one observation per loaded session. `GET /sessions?needs_reload=true` pages the sessions that need a reload, observing loaded sessions three at a time on the runtime's observation slots. Global services resolve saved selection on subsequent requests. Sessions reload explicitly.

Global extension defaults are validated against installed dependencies and capabilities before publication. Enabling one compaction strategy clears competing earlier true overrides to inheritance; multiple strategy enables in one patch return `400 selection_conflict`. Explicit false and null entries retain their meanings.

## Provider and MCP values

The providers group contains `default_profile` and `profiles`. A profile has `extension`, `endpoint`, `protocol`, `model`, nullable `effort`, nullable `image_edge`, nullable `account_id`, nullable `project` and `location` (cloud providers such as `vertex` keep their project and region here), and read-only `has_key`. Write-only `api_key` preserves the saved key when absent and removes it when null. `account_id` binds transport authentication to that saved account. The default profile must remain present or be replaced or cleared in the same patch.

Provider names contain 1 to 64 ASCII characters. The first character is a letter or digit. Remaining characters may also be `.`, `_`, or `-`. Validation rejects whitespace, unsupported protocols, invalid endpoints, and bindings to another provider's accounts.

The MCP group contains `definitions` and accepts write-only `validate_connection`. Public environment and header entries declare `source: "literal"` or `source: "env"`. Write-only `secrets` contains `bearer_token`, `environment`, and `headers`. Reads expose only `secret_presence`. Removing a definition removes its secrets. Environment entries belong to stdio transports; headers and bearer sources belong to HTTP transports.

Candidate validation checks names, source conflicts, timeouts, and transport fields before publication. Connection validation uses resolved candidate values. `validate_connection: false` skips probing and returns `validation: "skipped"`.

## Session configuration and catalog

Configuration contains explicit nullable `name`, workspace, provider profile, model, effort, preferences, selection overrides, configuration revision, and family revision. Name overrides preserve the automatic title. The automatic title follows every prompt, so it lives on the session and summary representations (`name`, `automatic_name`) and stays out of the configuration and its `ETag`: a prompt never makes a client's observed configuration stale. Preferences contain `pinned`, nullable `pin_order`, and `archived`; summaries also include shared opening counts.

Selection has separate `extensions`, `skills`, `instructions`, and `mcp` maps. Session overrides precede global preferences and defaults. MCP configured enablement also applies: a disabled definition remains unavailable.

The catalog separates fresh discovery from loaded commands. Inspection does not boot Python, prepare composition, execute commands, or alter the pinned prompt. Candidate IDs identify sources independently of preference keys. Invalid candidates can have null preference keys. Disabled and shadowed candidates remain visible, with eligibility and diagnostics.

Session selection edits carry `catalog_revision` and candidate IDs. Global capability edits carry `catalog_session_id`, `catalog_revision`, and choices; the daemon resolves preference keys. The actor checks fresh discovery under the settings lock before committing. Stale observations fail without changing configuration. Model and composition changes require an idle session.

The session owner commits editable fields, preferences, and selection together on SQLite. Its response contains the saved configuration resource and a session capture taken in the same actor operation; the capture's composition is then observed by the request, so the actor never waits on the runtime's observation queue. Saving selection does not claim composition reloaded. Explicit reload reads persisted desired selection, preserves the namespace when routes can be rebound, and reports preparation or replacement failures.

Workspace edits are standalone patches with the observed family revision. The native owner captures descendants and commits desired destinations together. Busy or parked descendants retain durable intent until cleanup and application succeed. New turns cannot start against a different active workspace.

## Persistence and recovery

Global settings remain in `config.json`, `extensions.json`, `capabilities.json`, `picker.json`, and `creds.json`. `settings-revisions.json` stores group publication counters, including secret-only changes. The settings journal publishes affected files atomically under one home lock. Malformed or unreadable documents fail operations. Writes retain unrelated fields and use sealed, synced temporary files.

`daemon/settings.gleam` exposes group operations. `daemon/settings_projection.gleam` owns read-only views, secret-presence projections, and cache priors; it returns native JSON maps so the publication owner retains the existing encoder and validators. `albedo_settings_http.erl` owns locks, conditional publication, and MCP probing outside the lock followed by locked revalidation. Provider validation and saved-profile normalization belong to `daemon/configuration`; MCP validation belongs to its extension. OAuth refresh, profile settings, and credential writes share the home lock.

`daemon/session_configuration.gleam` owns SQL preferences, selection, and visit identities. `session_configure.gleam` validates and installs actor configuration. `session_preferences.gleam` decodes and imports existing picker and session capability preferences once. Its native adapter keeps the home lock across file reads, SQL application, and journal cleanup: SQL commits an import marker before the settings journal removes imported fields. Global capability defaults remain file-owned.

Catalog revision includes inspected content and file identity, workspace, global composition revisions, and resolved choices. Unchanged inputs retain their revision. The settings lock does not make external filesystem edits atomic. Its key is the home path as given (the daemon absolutises its home once at start), so taking the lock makes no OS call: a settings read while the process is out of file descriptors reports an error, as every reader expects, instead of crashing the reader.

Deletion removes the session's SQL preferences and selection. Discovered skill and instruction files remain on disk. Credential migration notices come from `GET /server`; dismissal belongs to `ui.dismissed_notices`.
