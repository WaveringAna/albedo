# Persisted settings

The daemon owns provider profiles, MCP configuration, capability choices, and shared UI preferences. Clients keep drafts, transient view state, and the connection information needed to reach the daemon. The CLI fetches settings when connecting, after a stream reset, and when opening a settings screen. There are no local-write fallbacks. CLI and daemon must both support the `settings_api` capability advertised by `/health`.

## HTTP contract

Every route requires `Authorization: Bearer <daemon token>` and rejects requests with an `Origin` header. `/settings` is separate from `/health`.

| Route | Request | Response or effect |
| --- | --- | --- |
| `GET /settings` | None | `{profiles, mcp, capabilities, ui, credentials}` |
| `PUT /settings/providers/:name` | `{extension, baseUrl, model, protocol, apiKey?}` | Saves and selects the profile. An omitted key preserves the saved key. An empty key removes it. |
| `DELETE /settings/providers/:name` | None | Removes the profile and key. If it was active, selects the first remaining profile by name. |
| `PATCH /settings/ui` | Supplied `thinking` and `tools` booleans | Returns the saved UI preferences. |
| `PATCH /settings/ui/sessions/:id` | Supplied `pinned` and `archived` booleans | Returns the saved UI preferences. |
| `POST /settings/ui/sessions/:id/open` | None | Increments the open count and returns UI preferences. Clients must not automatically retry this operation. |
| `GET /sessions/:id/catalog` | None | Fresh skill and instruction candidates, preferences, extension state, and revision. |
| `POST /sessions/:id/catalog` | `{revision, id, scope, enabled}` | Revalidates the catalog, saves the choice, and reloads the session. |
| `POST /sessions/:id/settings/capabilities` | `{kind, name, scope, enabled}` | Saves the explicit choice and reloads the session. `enabled: null` removes the override. |
| `PUT /sessions/:id/settings/mcp/:name` | `{server, secrets?}` | Saves the server and optional credential patch, then reloads the session. |
| `DELETE /sessions/:id/settings/mcp/:name` | None | Removes the server and credentials, then reloads the session. |

`profiles` contains `{active, providers}`. Public profile fields are `extension`, `baseUrl`, `model`, `protocol`, and `hasKey`. API keys never appear in responses. `mcp` maps names to public server configuration. Its header and environment references contain environment variable names, never plaintext credentials. `credentials` has the same presence-only shape as `/auth/credentials`.

Provider names contain 1 to 64 ASCII characters. The first character must be a letter or digit. Remaining characters may also be `.`, `_`, or `-`. Whitespace, including a trailing newline, is rejected when saving profiles or validating existing configuration.

`capabilities` contains `global` and `sessions`. Each scope maps capability kinds to named boolean choices. Kinds are `skills`, `instructions`, and `mcp`. A session choice overrides its global choice; an absent global choice is enabled. Mutation scope is `global` or `session`, and `enabled` is required even when null.

`ui` contains `thinking`, `tools`, arrays of `pinned` and `archived` session IDs, and an `opens` map of session IDs to counts. These preferences are shared by clients. No live settings notifications are sent.

An MCP `secrets` patch may contain `bearerToken`, `headers`, and `env`. An absent field preserves its stored value; null removes it. Header and environment maps accept string values or null to remove one entry. A server uses the existing MCP format documented in [MCP](mcp.md).

Provider, UI, and snapshot errors return HTTP 400. Session settings errors return HTTP 409, including busy sessions, invalid changes, and failed reloads. Error bodies contain `{error: message}`. A successful provider mutation returns `{ok: true}`; session settings mutations return the session reload result. Failed form saves retain the draft and show the error.

## Skill and instruction catalog

`GET /sessions/:id/catalog` inspects the session workspace through daemon discovery. It does not prepare commands, reload extensions, or change the pinned prompt. The response contains `workspace`, an opaque `revision`, `extensions` with skills/instructions enabled booleans, bounded `diagnostics`, and `candidates`. Disabled and rejected candidates remain visible. Discovery applies metadata validation, size limits, and duplicate precedence. [Skills](skills.md) may link to external local installations and resources.

Each candidate contains `id`, `kind`, `title`, nullable `description`, lexical `source`, nullable `resolved_source`, nullable `preference_key`, `valid`, nullable `diagnostic`, and nullable `shadowed_by`. IDs identify source locations independently of preference keys. Duplicate skill rows have separate IDs but share the validated skill-name key. Instruction keys retain `project:<display>` or `global:<display>`.

`global_preference` and `session_override` are nullable booleans: null means no explicit choice. `effective_enabled` resolves the session choice, then the global choice, then the enabled default. `eligible` additionally requires a valid, winning candidate and an enabled extension. This describes fresh selection; prepared commands and prompt state can still reflect an earlier discovery until reload.

Catalog mutations use the row ID and revision, with `scope` set to `global` or `session`. `enabled: null` clears the explicit choice. Shadowed rows are read-only. Invalid rows with a preference key may be disabled or cleared but cannot be enabled. The daemon resolves the preference key and checks fresh discovery, workspace, preferences, and extension state under the settings mutation lock before writing. A changed revision returns HTTP 409 with `{code: "stale_catalog", error: message}` and leaves preferences and the prepared composition untouched. The client refreshes and requires a new user action; it does not replay the mutation. Inspection racing a workspace change also returns this error. Missing sessions return HTTP 404.

An unchanged catalog has a stable revision. Reading it or reloading unchanged extension inputs does not change the revision. Changes to bounded inspected content or file identity change the revision, including edits that preserve size and modification time. Retargeting a skill directory or its instruction link also changes the revision. Content beyond an oversized file's inspection limit is not read. This check does not make concurrent external filesystem edits atomic with a settings save.

## Persistence and recovery

The existing files remain authoritative on disk: `config.json`, `extensions.json`, `capabilities.json`, `picker.json`, and `creds.json`. Updates retain unrelated sections and record fields. Legacy flat provider configuration remains available as the `default` profile. This API requires no storage migration.

`daemon/settings.gleam` owns HTTP decoding and provider/UI operations. `harness/session_settings.gleam` owns capability/MCP changes, and `harness/albedo_settings_store.erl` provides their persistence and the shared transaction support. The runtime depends on these harness operations rather than daemon settings. Provider validation stays in `daemon/configuration`; MCP validation stays in its extension. `harness/albedo_settings_lock.erl` provides one mutation lock per home, including provider defaults and extension defaults or raised caps saved through existing commands. Credential operations, OAuth account refreshes, and settings save/reload/restoration all use the same per-home lock. There are no nested locks on different settings files. Same-process nested operations retain the outer lock. The lock is released if its holder exits.

`harness/capabilities.gleam` decodes capability preferences, applies session overrides to global defaults, and validates every known group before settings mutations or snapshots. Selection loads one immutable preference snapshot and validates each requested choice against it. Unscoped discovery and empty selections do not read preferences. `capabilities.json` reads and writes share a 1 MiB limit; oversized writes are rejected before replacement. `harness/albedo_capabilities.erl` provides bounded file reads.

The daemon validates files before changing them. A malformed or unreadable document fails the operation rather than becoming an empty default. Writes seal an exclusive temporary file to mode `0600` before writing its contents, sync it, and rename it into place.

Session settings messages enter the session actor, which checks idleness before persistence. The session then asks the runtime actor to save and reload. The runtime actor holds the mutation lock while saving, preparing the replacement composition, and restoring settings after preparation fails. The session actor never holds this lock across a call to the runtime actor. Restoration affects the settings file and credential entry involved in the mutation and preserves other credential entries. The runtime retains the previous composition on preparation failure. Errors explicitly report restoration failures. These operations are not crash-atomic transactions across multiple files.

A prompt-notice save failure occurs after a successful composition reload. The daemon reports it as a warning in the reload response, so callers retain the newly applied settings.

Session deletion removes its picker preferences and capability overrides in the daemon. Skill and instruction source files remain content discovered from the filesystem. `agentName`, client-specific overrides, and live settings notifications are outside this interface.
