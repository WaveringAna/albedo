# HTTP API design

Status: implemented contract for daemon protocol 3.

[openapi.yaml](openapi.yaml) owns the exact request, response, parameter, header,
and SSE payload shapes. This document owns behavior: ordering, atomicity,
retry, recovery, and resource ownership. Both documents must agree.
The OpenAPI version is a document-format version; daemon protocol 3 is a
separate compatibility decision.

[API architecture](http-api-architecture.md) explains state ownership and settings
crash recovery.

This document defines daemon protocol 3. The daemon and CLI use this contract
together. It defines no compatibility
aliases or legacy response readers. Changes to this contract require an update
here, a client impact review, and behavioral tests before implementation.

The API serves terminal, web, and desktop clients. All current TUI features
remain available. Installation discovery, local launch, and the interactive
restart offer remain application policy, outside the API connection.

The [resource map](#resource-map) lists routes. The [HTTP rules](#http-rules)
define authentication, errors, and retries. [Sessions](#sessions-and-durable-input)
and [SSE](#sse-delivery-and-recovery) define chat and recovery.
[Extension contracts](#extension-contracts) define optional domain operations.
The [feature checklist](#existing-feature-coverage) and
[behavioral verification](#verification) describe the supported workflows.

## Design decisions

- Resources own their data and operations. A screen does not get its own route.
- A session read includes the state needed to open a chat. A collection read
  includes the state needed to browse sessions or draw an agent family.
- Ordinary HTTP requests perform changes. SSE delivers live updates.
- JSON and SSE use the same session resource URL, selected by `Accept`.
- Input IDs identify user intent across retries. Stream cursors identify an
  actor lifetime and position. Transcript checkpoints identify durable history.
  These identities are separate.
- Core operations have named, typed contracts. Extensions own separate domain
  routes. A command menu entry points to its canonical operation.
- The daemon owns execution state, argument parsing, storage inspection, and
  progress. Clients own navigation, rendering, local drafts, and confirmations.
- Bounds apply before subscriber mailboxes. Model execution does not wait for
  a client to read its socket.

SSE is the sole core streaming transport. The current UI needs server-to-client
updates, and SSE retains the existing replay and bounded delivery design.
This contract does not add WebSocket authentication or subscriptions.
It makes no claim that changing route organization reduces CPU or memory.

### Reading and changing the wire contract

Each OpenAPI operation names its request and accepted response schemas.
Required properties are listed explicitly. Nullable fields accept JSON null;
optional fields may be omitted. Requests reject unlisted fields. Response
schemas describe what the server emits; clients may ignore new fields.
Tool, provider-private, and extension-specific bodies use the explicitly named
`DynamicJSON` schema. Core resource envelopes have typed fields.

SSE `itemSchema` describes a parsed event whose `data` string contains JSON.
Decode that string and validate its `contentSchema` separately. Ordinary schema
validation does not assert string-encoded content. The wire contract uses
[OpenAPI 3.2 streaming definitions](https://spec.openapis.org/oas/v3.2#special-considerations-for-server-sent-events).
The `x-max-utf8-bytes`, `x-max-encoded-bytes`, and content-byte annotations
record byte limits that also need explicit runtime checks. JSON Schema
`maxLength` counts Unicode code points, not encoded bytes.

Agree on a shape by editing the operation and its shared schemas, adding a
complete example, and reviewing the affected behavior here. Validate the
document and examples before changing either implementation. Validate real daemon replies and decoded SSE batches in workflow tests;
shape validation does not prove ordering, atomicity, or safe retry.

## Resource map

The tables list every platform path template. Extension paths appear in their
own section. An omitted method is unsupported. `GET` defaults to JSON.

| Path | Methods | Responsibility |
| --- | --- | --- |
| `/server` | GET | Readiness, protocol, capabilities, build, quota, notices |
| `/server/shutdown` | POST | Explicitly stop the identified daemon instance |
| `/settings` | GET, PATCH | Shared defaults, provider profiles, MCP, secrets, UI preferences |
| `/storage` | GET | Online storage accounting |
| `/sessions` | GET | Filtered session summaries, or collection invalidations over SSE |
| `/sessions/{session_id}` | PUT, GET, PATCH, DELETE | Create, attach, configure, delete, or watch a session |
| `/sessions/{session_id}/visits/{visit_id}` | PUT | Count one deliberate opening without counting retries |
| `/sessions/{session_id}/inputs/{input_id}` | PUT, GET | Admit immutable user input and read its durable outcome |
| `/sessions/{session_id}/inputs/{input_id}/cancel` | POST | Cancel that input or request interruption of its exclusive turn |
| `/sessions/{session_id}/interrupt` | POST | Interrupt a captured turn and cancel captured waiting inputs |
| `/sessions/{session_id}/history` | GET | Bounded transcript pages or checkpoint summaries |
| `/sessions/{session_id}/history/{entry_id}` | GET | Read full content of a large transcript entry in bounded pieces |
| `/sessions/{session_id}/context` | GET | Prepared request inspection and provider request records |
| `/sessions/{session_id}/catalog` | GET | Fresh discovery and separately identified loaded composition |
| `/sessions/{session_id}/reload` | POST | Reload session composition, model catalogs, or both |
| `/sessions/{session_id}/kernel/upgrade` | POST | Explicitly replace this session's Python kernel |
| `/sessions/{session_id}/compaction` | POST | Compact the model-facing conversation |
| `/models` | GET | Provider model metadata, effort choices, context limits, cache policy |
| `/workspaces` | GET | Recent workspaces or one directory with optional repository preview |
| `/hosts` | GET | Known hosts or one host's cached probe state |
| `/hosts/{host}/probe` | POST | Explicitly refresh a host probe |
| `/auth` | GET | Provider login methods and redacted account metadata |
| `/auth/logins/{login_id}` | PUT, GET, PATCH, DELETE | Start, inspect, answer, or cancel a provider login |
| `/auth/accounts/{account_id}` | DELETE | Remove a provider account |

There is no generic request endpoint, command dispatcher, operation lookup
route, separate status route, preview route, agent tree route, or stream suffix.
The underlying durable admission records remain owned by the daemon. Their
public representation is the session or input whose identity they protect.

### Opening a chat

1. Use the supplied base URL and bearer token to read `/server`. Check protocol
   and required capabilities before opening a screen.
2. Read `/sessions` for the picker or family graph. Each row includes its
   metadata and bounded live state.
3. Read the selected session. Install its history, pending inputs, status,
   progress, and cursor together. Count a deliberate opening with one identified
   visit; background reads do not count.
4. Watch that same session URL as SSE, passing the installed cursor pair.
   Apply subsequent events, or replace the daemon-derived view on reset.
5. Send a message with an identified input PUT. Keep its local handle until
   the returned decision or matching stream event resolves it. Cancellation
   targets that input identity.
6. Fetch older history by durable position. Open context, catalog, or extension
   resources when the user needs them. Use the validator already displayed
   with a resource when editing it.

## HTTP rules

### Addressing and authentication

A client receives a base URL and daemon bearer token. Native local clients may
read the protected discovery record. Other clients receive both values through
explicit connection setup. No API method reads client installation files,
launches a daemon, or replaces one.

Every platform request, including SSE, uses
`Authorization: Bearer <daemon-token>`. The token grants operator access to this
daemon. This protocol has no user accounts, tenant isolation, or session ACLs.
Provider OAuth accounts are model-provider credentials, not daemon identities.
Browser OPTIONS preflights are the exception to bearer presentation. They
return only allowed request metadata and cannot read or mutate resources.

The default listener remains loopback. Connections across an untrusted network
require HTTPS or an encrypted tunnel. Tokens never appear in URLs, response
bodies, diagnostic logs, or stream events.

Browser clients use `fetch` for JSON and SSE so they can send the authorization
header. Native `EventSource` does not expose arbitrary request headers.
[The SSE specification](https://html.spec.whatwg.org/multipage/server-sent-events.html#the-eventsource-interface)
defines its constructor and stream format.

Browser access uses an operator-configured list of exact allowed origins.
The daemon validates `Origin` before routing or reading a body. Allowed
preflights advertise the supported method and headers, including `Authorization`,
`Content-Type`, `If-Match`, and `If-None-Match`. Responses vary by `Origin` and
expose `ETag`, `Location`, and `Retry-After`. There are no authentication cookies
or wildcard origins. Origin approval does not replace the bearer check.
This follows the [Fetch CORS protocol](https://fetch.spec.whatwg.org/#http-cors-protocol).

The daemon validates the requested host against its listener and configured
public addresses. A supplied origin or host never grants additional permission.
Optional extension intake routes declare their own authentication policy.

### Encoding, limits, and pagination

JSON uses UTF-8, `snake_case` field names, and tagged objects for variants.
IDs are opaque strings. Paths and query values use ordinary percent encoding.
Core timestamps are UTC RFC 3339 strings. Unknown historical timestamps are null.
Durations use explicitly named units.
Counters and sequence numbers are integers from zero through `2^53 - 1`.

Unknown request fields, duplicate JSON keys, invalid enum values, malformed
query values, and unknown query parameters return `400 invalid_request`.
Requests do not silently substitute defaults for invalid values. Unknown
response fields may be ignored. Missing required fields and invalid known
variants fail decoding.

`PATCH` uses `application/merge-patch+json`. Omission keeps a value, `null`
removes an override or optional value, and `false` remains a real value.
Arrays replace the complete array. Writable fields are listed for each resource.
[JSON Merge Patch](https://www.rfc-editor.org/rfc/rfc7396.html)
defines these rules.

Ordinary JSON request bodies have a 64 KiB limit. Input admission has a
9,200,000-byte limit, including encoded images. JSON responses and SSE data
frames have a 1 MiB limit. Resource-specific limits below apply as well.
HTTP body framing accepts valid fixed-length and chunked requests, enforcing
the same byte limit while reading. Ambiguous framing, unsupported content
encoding, and incomplete bodies fail without executing the operation.

Lists return `{ "items": [], "next": null }`. `next` is an opaque continuation
token tied to the query and representation, including `limit`. Follow-up requests
retain the original query and add `next`. Default `limit` is 50; maximum is
200. Each page also respects its encoded byte limit, including JSON escaping.
Catalog entries, glances, input outcomes, and reset snapshots obey that bound
even when their item counts fit. Large content uses its documented paging path;
summary text is shortened explicitly. A single catalog entry is at most 64 KiB.
Session glances include at most 16 entries of 8 KiB each. Tokens never contain credentials
and cannot authorize access. A token for another query returns `400`.
Missing singleton resources return `404`; an empty collection returns `200`.

Collection traversal uses a stable sort key and ID as its tie breaker.
Sessions use most recent activity first. A traversal is not a frozen global
snapshot: concurrent edits can move rows. Clients key rows by ID and refresh
on invalidation. History traversals use immutable transcript positions and
do not have this limitation.

### Revisions and errors

An `ETag` validates the complete selected JSON representation. Configuration
has a separate representation from volatile session state. Session reads expose
the URL and validator for `view=configuration`; settings reads expose the URL
and validator for each `group`. Editing those representations uses `If-Match`
without conflicting with unrelated progress or another settings group.
Extension item reads likewise expose the item's observed URL and validator.

`PATCH` and conditional `DELETE` require the observed `If-Match`. Missing
preconditions return `428`; stale ones return `412`. Checks and the corresponding
commit occur under the owning resource's serialization or transaction boundary.
Validators are opaque; clients never derive them from an integer revision.
Mutation envelopes carry new resource validators explicitly and are not cached
as canonical read representations.

Errors use `application/problem+json`, with `type: "about:blank"`, `title`,
`status`, `detail`, and a stable Albedo `code`. An optional `fields` array
contains JSON pointers and safe explanations. Decisions described below can
add a typed `decision` field. Clients branch on status and code, never wording.
Raw request bodies, secrets, and provider responses do not appear in errors.
[Problem Details](https://www.rfc-editor.org/rfc/rfc9457.html)
defines the common envelope.

| Status | Meaning |
| --- | --- |
| 200 | A read or synchronous operation returned its documented result |
| 201 | A resource was created; `Location` identifies it |
| 202 | Input is durably accepted, or an explicitly identified action is underway |
| 204 | A deletion or cancellation needs no response body |
| 400 | Invalid syntax, fields, query, or identity timestamp |
| 401 | Missing or invalid daemon token; includes `WWW-Authenticate: Bearer` |
| 403 | Disallowed browser origin or caller permission |
| 404 | Unknown current resource or disabled extension route |
| 405 | Known path, unsupported method; includes `Allow` |
| 406 | Unsupported response media type |
| 409 | Busy state, identity conflict, stale catalog, or incompatible operation |
| 410 | Retained deletion, expired identity, or obsolete prepared context |
| 412 | The observed representation or creation precondition no longer holds |
| 413 | Body exceeds its limit |
| 415 | Unsupported request media type |
| 428 | Required precondition is missing |
| 429 | Admission or rate limit; includes `Retry-After` where a later new intent can succeed |
| 503 | Owner, storage, or upstream preparation is unavailable |

All authenticated data responses use `Cache-Control: no-store`. Clients may
keep in-memory resource state and validators. Errors after SSE headers use the
stream failure contract rather than pretending to change the HTTP status.

### Retries and cancellation

Reads can retry transient connection failures with capped backoff and jitter.
They remain subject to the caller's deadline. Authentication and protocol
errors are actionable failures, not evidence that a daemon is absent.

Session creation, input admission, visits, and login creation retain the
original ID and encoded intent during recovery. Other changes have no automatic
replay after a lost response. A precondition or a resource-specific identity can
make an explicit retry safe, as specified below.

Canceling a client context stops its requests and subscriptions. It does not
undo an accepted input, interrupt a shared turn, stop a detached daemon, or
authorize replacing one. Those are separate operations. Transport cancellation
after a mutation was sent can leave its outcome uncertain.

## Server, settings, and storage

### Server identity and shutdown

`GET /server` returns `instance_id`, `protocol`, `state`, `capabilities`,
`build`, `digest`, `extensions`, `quota`, and `notices`. `state` is `ready` or `draining`.
`instance_id` changes at each daemon startup. `build` and `digest` are nullable update
information. Attachment requires protocol 3; optional operations check the
advertised capability before invocation.

Capabilities are a map from stable feature names to integer contract versions.
The required version-1 features are `durable_inputs`, `session_replay`,
`collection_invalidation`, and `tool_progress`. Optional features include
`context`, `catalog`, `workspace_browsing`, `host_probes`, `provider_auth`, and
`storage_report`. Extension entries identify enabled services and their
contract versions. Builds cannot substitute for protocol compatibility.

`quota` contains the latest recorded observations per account and limit. Each
observation includes durable sequence, provider and account labels, limit ID,
plan, observed percentage, window, reset time, scope, status, source, and safe
failure details. Unknown percentage is null. `include=quota_history` adds the
same records newest first, paged by `limit` and `next`.
Notices have `id`, `kind`, and `message`; dismissal is a shared UI setting and does not consume a read.

`POST /server/shutdown` accepts `instance_id` and `timeout_ms`, default 5,000
and maximum 30,000. A different instance returns `409 instance_changed`.
The daemon marks itself draining, refuses new admissions, stops active turns,
flushes durable state, and closes. Accepted waiting inputs remain durable for
the replacement daemon. `202` reports `instance_id` and `state: "draining"`.
The client observes closure with a bounded wait. It cannot use this endpoint
to start the replacement.

The interactive CLI still offers to keep or restart a discovered daemon.
Keeping it is the default. Its approved instance identifies the shutdown
target. [Daemon attachment and local startup](daemon-lifecycle.md) owns this
user flow and deliberate operator overrides.

### Shared settings

`GET /settings` returns these groups and `group_resources`, a map of group
name to canonical URL and `etag`. `GET /settings?group={name}` returns just
that group's canonical representation and its `ETag` header.

| Group | Fields and meaning |
| --- | --- |
| `providers` | `default_profile` and `profiles` keyed by name. Profiles contain provider extension, endpoint, default model, effort, nullable image edge, nullable OAuth account, and `has_key`. |
| `mcp` | `definitions` keyed by name: configured enablement, transport, URL or command with arguments, nonsecret environment and headers, timeouts, and secret-presence metadata. |
| `extensions` | Global default enablement keyed by extension name. |
| `capabilities` | Global skill, instruction, and MCP preferences keyed by their stable preference key. |
| `models` | Per-model raised context choices and the cache TTL prior table, with source and units. |
| `ui` | `thinking`, `tools`, and `dismissed_notices`. Per-session pin, archive, and visits are session fields. |

`PATCH /settings?group={name}` changes exactly one group per request. Its body
is a merge patch of that group's fields, with the observed group `If-Match`.
The group owner checks its validator in the same commit boundary. It validates the
entire patch before effects and commits that group's desired state atomically.
Provider profile data and its secrets have one settings owner; MCP definitions
and their secrets have another. Their persistence must recover the complete
old or complete new group after a crash, including when storage uses files.
A multi-group patch returns `400`; there is no partial PATCH success.

Provider keys and MCP secrets are write-only patch fields. Provider
`api_key`, MCP `bearer_token`, and individual secret header or environment
entries accept a replacement string or `null` for removal. Omission retains
the existing secret. Reads return presence and secret names, never values.
Response-only presence fields are rejected on writes.

MCP changes validate the candidate connection before saving. A failed probe
keeps the previous definition and secrets. This removes the client-side
save-then-undo sequence. A request can deliberately set `validate_connection`
to `false`; that control is not persisted. The response reports validation
state and safe diagnostics.

Changing a profile does not implicitly select it. Changing
`providers.default_profile` explicitly sets the default for new sessions.
Changing a per-model raised-cap choice affects that model's next prepared
requests across sessions. `models.raised_caps` maps returned `cap_key` values
to booleans: true uses the advertised maximum, false uses the ordinary limit,
and null removes a choice. Missing choices default to false. Clients do not
construct cap keys. Existing requests keep their captured settings.

Global capability selection accepts `catalog_session_id`, `catalog_revision`,
and candidate-ID `choices`; the daemon resolves the IDs to preference keys.
The read representation exposes persisted preferences. These write-only
selection fields prevent stale discovery from changing a different file.

The provider group uses these exact profile fields: `extension`, `endpoint`,
`protocol`, `model`, `effort`, `image_edge`, `account_id`, and response-only
`has_key`. Protocol is `responses` or `chat_completions`. Nullable fields keep
their documented absence; model and extension are required on creation.
Deleting a profile removes its key. Removing the selected default requires
an explicit replacement or `default_profile: null` in the same atomic patch.

For example, a provider-group patch selects a profile explicitly:

```json
{
	"default_profile": "personal",
	"profiles": {
		"personal": {
			"extension": "openai",
			"endpoint": "https://provider.example/v1",
			"protocol": "responses",
			"model": "chosen-model",
			"effort": null,
			"image_edge": null,
			"account_id": null,
			"api_key": "replacement-secret"
		}
	}
}
```

An MCP definition has `enabled`, `transport: "stdio"|"http"`, `command`,
`arguments`, `cwd`, `url`, `environment`, `headers`, `bearer_token_env_var`,
`enabled_tools`, `disabled_tools`, `startup_timeout_ms`, and `call_timeout_ms`.
Transport selects the applicable command or URL fields. Environment and header
values are tagged `{ "source": "literal"|"env", "value": ... }`. Environment
references resolve on the daemon host. Tool filters preserve the current MCP
allow and deny controls. Definition enablement defaults to true.

Writes add a `secrets` object containing `bearer_token`, `environment`, and
`headers`. Secret maps accept replacement strings and per-key null removals.
Reads replace that object with `secret_presence`, containing bearer presence
and the two lists of names. Deleting a definition deletes its associated secrets.
Candidate validation rejects duplicate environment or header names across public
and secret maps. Header names compare case-insensitively. It also rejects more
than one bearer source: `bearer_token_env_var`, `secrets.bearer_token`, or an
Authorization header. Switching sources requires removing the old source in
the same patch. The validated connection uses the candidate's resolved values.
`validate_connection` is a write-only group control, outside definitions:

```json
{
	"validate_connection": true,
	"definitions": {
		"example": {
			"enabled": true,
			"transport": "http",
			"url": "https://tools.example/mcp",
			"secrets": {
				"bearer_token": "replacement-secret",
				"headers": {"X-Old-Key": null}
			}
		}
	}
}
```

MCP capability preferences are separate from configured enablement. Effective
selection uses the session override, then the global preference, then true.
A definition with `enabled: false` remains unavailable regardless of selection.
Global MCP preference changes use the same catalog revision guard as global
skill and instruction choices. Other group writes use `extensions.defaults`,
`models.raised_caps`, or `ui.thinking`, `ui.tools`, and `ui.dismissed_notices`.
Capabilities read as `preferences` keyed by stable preference key; their
write-only selection fields are siblings in the capabilities group.

Every successful patch returns `{ "group": ..., "resource": ..., "application": ... }`.
`resource` contains the updated value, canonical URL, and validator.
`application` includes desired revision, active service revision,
`needs_reload_count`, up to 200 affected session IDs, `more`, and warnings.
`GET /sessions?needs_reload=true` provides the complete paged set.
Persisted defaults do not claim that every open
session reloaded. Global services use the new desired state on subsequent
requests. Sessions apply composition through their explicit reload operation.

### Storage accounting

`GET /storage` returns `database`, `sessions`, `images`, `files`, and
`measured_at`. Session items include ID, title, workspace, creation and activity
timestamps, and estimated content bytes. Images report shared count and bytes.
Database fields include main-file bytes, WAL plus SHM bytes, page size, total
pages, free pages, and estimated used bytes. Files contain daemon-owned state
file categories, sizes, and cleanup-candidate metadata.
The database keys are `main_file_bytes`, `wal_bytes`, `page_size_bytes`,
`page_count`, `free_page_count`, and `used_bytes`. Sessions have
`estimated_content_bytes`; shared images have `count` and `bytes`.

Session estimates count pinned context, transcript content, cell sources,
payloads, and traces. Shared images count once outside session estimates.
Estimates do not claim allocated disk space per session. Database measurements
share one read boundary; filesystem measurements describe the inspection period.
Session and file lists use separate `next` tokens within this response, with
each token identifying its section. Totals always cover the complete store.

An online client needs no filesystem or Python access. Returned paths describe
the daemon's files and never authorize local deletion. Offline diagnosis and
approved cleanup remain explicit local operations under the ownership lock.

## Sessions and durable input

### Session representations

`SessionSummary` contains `id`, `name`, `automatic_name`, `workspace`, `parent_id`,
`root_id`, `address`, `depth`, `closed`, `created_at`, `activity_at`,
`provider_profile`, `model`, `effort`, `status`, `preview`, `preferences`,
`current_progress`, `activity`, and `cursor`. Each summary captures its own
status, progress, activity, and cursor together. Family `address` stays stable
when display name changes.

`status` contains `phase`, nullable `run_id`, `interrupt_requested`, and a
nullable safe `blocking_reason`. Phases are `idle`, `preparing`, `generating`,
`running`, `interrupting`, and `compacting`. `preview` has at most 256 Unicode
scalar values and 1,024 UTF-8 bytes, and includes the durable transcript row count.
One transcript row can produce several history entries. Continuation markers
do not add transcript rows.
`preferences` contains `pinned`, nullable `pin_order`, `archived`, and `opens`.
Pin order preserves the shared ordered pin list. Pinning assigns its order once;
repeating `pinned: true` does not move the row or increment anything.
Unpinning clears the order. Only `pinned` and `archived` are writable; opens
and pin order are read-only.

`activity` provides the agent graph's live tails without a session subscription
for every node. It contains up to 12 `lines`, each with `kind` and `text`.
Kinds are `assistant`, `thinking`, `tool`, `input`, `note`, and `error`.
The current partial line is included. Each line has at most 256 Unicode scalar
values and 1,024 UTF-8 bytes; the complete encoded activity object is at most
16 KiB, shortening oldest lines first. Tool-argument previews stay in
`current_progress` and are not copied into these lines.

Activity also includes `output_scalars`, `output_utf8_bytes`, and `observed_at`.
The counters cover generated text and reasoning in this actor generation.
Clients derive display rates from successive samples and decay them while
quiet. Nullable `latest_input: { "input_id": ..., "source": ..., "bytes": ... }`
and `latest_answer: { "message_id": ..., "bytes": ... }` let clients animate
new human input and completed root answers by identity. Input source is `chat`,
`agent`, or `system`; bytes count UTF-8 display text. Initial reads install
these identities without replaying old animations. The actor maintains this
bounded activity once, before subscriber fan-out. Full content stays in history.

`Session` adds:

- `creation`, the immutable submitted creation intent and separately resolved defaults.
- `revision` and `family_revision` for conditional edits and family operations.
- `configuration_resource`, containing its canonical URL, value, and `etag`.
- `workspace_change`, nullable desired versus active workspace and deferred state.
- `selection`, containing session overrides and effective selections.
- `composition`, containing desired and loaded revisions, `needs_reload`,
  dependencies, quarantine diagnostics, and capability availability.
- `kernel`, containing state, build identity, staleness reasons, and live-job
  count. No Python variables or process handles leave the daemon.
- `pending_inputs`, at most 32 bounded input summaries with acceptance order,
  and `input_order`, the greatest order ever accepted into this session.
- `usage`, including token and cache counters, elapsed time, model limits,
  observed cache TTL, and time-indexed cache fade observations.
- `history`, a bounded recent page, with its older-page token.
- `cursor`, the generation and sequence captured with the live state.
- `glances`, bounded extension-provided summaries and links to their resources.

`input_order` is zero before the first admission.

Pending summaries include input ID, kind, display preview, admission time,
acceptance order, delivery state, and blocking reason. They omit image content
and expanded model input. Collection summaries and detail reads do not parse
tool arguments or reconstruct previews.

### Collection reads

`GET /sessions` accepts `scope=roots|all` and optional `parent_id`, `family_id`,
`workspace`, `search`, `archived`, and `needs_reload`. The parent and family
filters are mutually exclusive. `family_id` selects the containing root
and all descendants. `search` matches display names and ID prefixes.
`sort=activity|frequent` defaults to activity; frequent sorts by opens, activity,
and ID. Pinned state remains available for client grouping.

Parent and family queries default to `scope=all`; other queries default to roots.
An explicitly supplied `scope=roots` with a parent or family filter returns `400`.
The result is a page of `SessionSummary` objects. A family query also returns
`family: { "root_id": ..., "revision": ... }`. Agent trees are drawn from
`parent_id`, `address`, and `depth`; there is no second agent identity or graph
endpoint. Clients can traverse all pages. A missing requested family returns
`404`, while an existing parent with no children returns an empty page.

`Accept: text/event-stream` selects the collection watch described below.

### Creation, forks, and children

`PUT /sessions/{session_id}` requires a fresh client-generated UUIDv7 and
`If-None-Match: *`. Its body is one creation variant:

| `kind` | Fields | Behavior |
| --- | --- | --- |
| `new` | `workspace`; optional `name`, `provider_profile`, `model`, `effort` | Create an independent session. |
| `fork` | `source_session_id`, `checkpoint_id`; optional `name` | Copy the durable prefix and selection overrides into an independent session. |
| `child` | `parent_id`, `address`, `name`, `initial_input_id`, `task`; optional `model`, `effort` | Create a family member inheriting workspace and provider, with an initial durable task. |

The daemon resolves defaults once at first admission. Child creation, family
membership, creation decision, and initial input admission commit together.
A rejected task leaves no orphan child. The child task is ordinary identified
user input. Forks preserve full durable tool arguments and results, image
references, captured execution traces, continuation boundaries, and selected extension overrides.
They copy no Python namespace, live jobs, progress, or usage totals. The daemon
closes incomplete tool exchanges at the chosen checkpoint using its existing
history rules.

Success returns `201` with `Session`, its `Location`, and `ETag`. A retained
rejected creation returns its original problem and admission status on retry.
An existing session fails the create precondition with `412`. Recovery reads
the session and compares `creation.submitted` structurally with the original
intent. Optional creation fields absent from the request appear as null in
this descriptor. String contents stay exact. Matching intent proves creation;
a different intent is an ID conflict. Resolved workspace and provider defaults
appear in `creation.resolved` and do not change the submitted descriptor.
Current model, title, or workspace cannot replace that provenance check.
Sessions stored before immutable provenance was recorded return
`creation: null`. They remain readable, editable, and forkable, but cannot
prove a matching creation request. Migration never invents submitted intent
from their current configuration. Every newly admitted creation has provenance.
Conditional creation follows
[HTTP If-None-Match semantics](https://www.rfc-editor.org/rfc/rfc9110.html#section-13.1.2).

Creation decisions and deletion tombstones remain queryable at the same URI.
Rejected creation reads return their original problem with `decision` metadata;
deleted session reads return `410 session_deleted` with creation provenance.
An unknown young ID returns `404`, which cannot prove an in-flight PUT will
never commit. Recovery retains the same intent and identity.

`GET /sessions/{session_id}` returns `Session`. `tail`, default 100 and maximum
200, selects the recent history window. The byte bound can shorten the window.
Status, progress, pending ownership, and the cursor share one session-actor
capture. History is read through that capture's durable high-water mark.
The configuration view does not accept `tail` or stream cursor parameters.

### Changes, visits, and deletion

`GET /sessions/{session_id}?view=configuration` returns only editable metadata,
preferences, overrides, revision, and family revision, with a strong `ETag`.
The full session read embeds this same value and validator for an edit.
`PATCH /sessions/{session_id}?view=configuration` accepts `name`, `provider_profile`,
`model`, `effort`, `preferences`, and `selection`. An empty or null name restores
the automatic title for a root, or the original family name for a child.
Pin and archive changes are shared preferences. Model and
composition changes require an idle session. Selection maps accept true,
false, or null to clear the override and inherit the global default.
A patch enabling one compaction strategy clears competing earlier true
overrides to inheritance; enabling multiple strategies in the same patch
returns `400 selection_conflict`, and explicit false or null choices keep
their meaning.
When model or profile changes without an explicit effort, keep a supported
current effort, then try the profile default and model default. An explicit
null clears effort; an explicit unsupported level fails validation.
Selection has `extensions`, `skills`, `instructions`, and `mcp` maps keyed by
their catalog IDs. MCP entries enable or disable installed server definitions;
their IDs are stable definition names. Definitions and secrets belong to shared
settings. Skill and instruction choices additionally include the write-only
`catalog_revision` from the discovery read.
A stale catalog returns `409 catalog_changed`.
The session owner prepares a valid candidate before committing the patch.
Editable session data and preferences commit together through the store owner.
The result includes the new configuration resource and captured session state.
PATCHes set explicit values; they never toggle or increment preferences.

For example, a session selection patch clears one override and disables a skill:

```json
{
	"selection": {
		"extensions": {"browser": null},
		"skills": {"candidate-123": false}
	},
	"catalog_revision": "observed-discovery-revision"
}
```

Workspace changes use the same PATCH with `workspace` as its only change,
alongside the observed `family_revision` as a write-only precondition.
The daemon validates the destination and captures following descendants under
the family revision. A busy target session returns `409 session_busy` before
any move; the UI retains its deferred move intent. An idle parent can move while
a descendant is busy. Destination metadata and deferred descendant intents
commit in one store transaction before kernel cleanup. Busy descendants finish
their captured turn in the old workspace and apply the new workspace at idle.
Their `workspace_change` reports desired location, active location, and state
`deferred` or `applying`. This intent survives client disconnect and daemon restart.

The move preserves transcript and family addresses, resets affected kernels
and Python namespaces, and returns applied and deferred counts, bounded ID
lists, `truncated`, and cleanup warnings. When truncated, clients refresh the
family rather than repeating a move to discover its result.
Cleanup failure cannot be reported as rollback of a committed move.
Affected sessions cannot begin a new turn in an old kernel after the commit.
A later explicit move supersedes the earlier desired location by revision;
a delayed completion cannot restore an older choice. New descendants inherit
the parent's desired workspace at their admission.

Model selection does not implicitly change the default for new sessions.
The TUI's model picker explicitly updates the shared default when appropriate.
A later default or cap failure leaves a confirmed session model change visible.

`PUT /sessions/{session_id}/visits/{visit_id}` accepts an empty object and counts
one deliberate attachment. Repeating the UUIDv7 returns the same count without
incrementing it again. Background refreshes do not create visits. Reads never
change opens. Deleted sessions cannot be revived by a visit.

`DELETE /sessions/{session_id}?view=configuration` defaults to `scope=leaf`.
It requires the configuration `If-Match`, an idle session, and no children.
`scope=subtree` also requires
the `family_revision` query parameter from the family read. The daemon captures exactly that
membership, prevents new child admission during this operation, interrupts
members, cancels pending inputs, and deletes deepest first.

Deletion returns `200` with `state: "complete"|"partial"`, `deleted_count`,
`remaining_count`, `deleted_ids`, and `remaining` objects containing ID and
safe reason. Counts cover the captured operation; lists contain up to 200
IDs each and can shorten further to meet the byte limit, with `truncated: true`.
Clients refresh the authoritative family or read known deletion tombstones.
They never repeat deletion to page its result. Partial deletion is visible.
Any successful deletion changes the family revision. A retry with the old
revision cannot broaden the operation or delete new descendants. The client
refreshes and confirms the remaining membership before a new deletion attempt.
This operation has no automatic replay after transport loss.

### Input admission and outcomes

`PUT /sessions/{session_id}/inputs/{input_id}` uses a client UUIDv7. The body
has optional `client_id` for echo correlation and exactly one variant:

| `kind` | Fields |
| --- | --- |
| `message` | `text`; optional `image` with `mime_type` and base64 `data` |
| `continue` | No content fields |
| `skill` | `candidate_id`, `catalog_revision`, and `arguments` as text |
| `command` | `command_id` and typed `arguments`; only a catalog entry with `delivery: "input"` |

A message requires nonblank text or an image. Images accept PNG, JPEG, GIF,
and WebP, subject to decoding, dimension, and selected-provider bounds. The
daemon preserves original upload metadata and the full durable payload.
Provider-specific fitting stays daemon-owned and appears in durable history.

Command inputs prepare a user turn. They do not invoke arbitrary management
handlers. Their preparation produces content, runs outside the session actor,
and persists the resolved content before transcript consumption. Preparation
must be repeatable without external side effects. An extension that performs
effects exposes its own domain operation instead.

The first accepted PUT returns `202` with `Input`. An identical PUT returns
the retained admission decision and current delivery state, using the original
admission status. Changed intent under the same ID returns `409 input_conflict`.
Echo-only `client_id` does not change identity. Lookup happens before current
workspace, skill, provider, and queue validation. Defaults and skill content
resolve once. Rejected decisions are durable, including `429 queue_full`.

`GET /sessions/{session_id}/inputs/{input_id}` returns the known decision even
after session deletion. `Input` contains `id`, `session_id`, `kind`,
`admission`, `accepted_at`, `acceptance_order`, `delivery`,
`blocking_reason`, `transcript_position`, and nullable `turn`. Admission is
`accepted` or `rejected`; rejected admission includes the original safe problem
and HTTP status. Delivery is `pending`, `committed`, or `cancelled`, and is
null for rejection. A continuation has a durable position without a text row.

`turn` identifies consumed turn membership and any durable terminal outcome:
`running`, `completed`, `interrupted`, `failed`, or `abandoned`. A restarted
daemon marks an unfinished previous run abandoned rather than claiming its
external effects completed. One turn can contain several inputs. Its nullable
`outcome` contains separately recorded detail; null means no detail was recorded.
Acceptance means safe storage. Commitment means transcript consumption.
Neither means that the assistant answered or a tool effect ran exactly once.

There are at most 32 waiting inputs per session. A duplicate consumes no slot.
Consumption commits transcript rows, images, input delivery state, turn
membership, and pending removal in one store transaction. Failure leaves the
input pending. Preparation failure exposes a safe blocking reason; it cannot
install a successful delivery state. Waiting accepted inputs survive restart.

Known pending identities and inputs belonging to an unfinished turn never
expire. An input becomes terminal only when delivery and its associated turn
are terminal. Its admission record remains for seven days after that point.
Rejected decisions become terminal at rejection. Live sessions retain creation provenance
for their lifetime. Deleted sessions retain tombstones for seven days.
Known decisions are checked first. Unknown UUIDv7 identities older than seven
days return `410 identity_expired` and cannot execute; identities more than
five minutes ahead return `400 identity_future`. This prevents recreation after
deduplication records expire. These rules also cover visit identities.

Recovery queries the same input URI and may resend the exact same PUT within
the caller's deadline. `404` means unknown at the time of the read, not safe
to invent another ID. `410` stops automatic recovery and keeps an unresolved
UI row. A matching durable event can still reconcile that row later.

### Targeted cancellation and interruption

`POST /sessions/{session_id}/inputs/{input_id}/cancel` accepts an empty object.
It returns the current `Input` and one `result`:

- `cancelled`: a waiting input was removed and its cancellation committed.
- `interrupt_requested`: its current turn belongs exclusively to this input.
- `shared_running`: other inputs share the active turn; the turn continues.
- `not_pending`: no waiting or interruptible exclusive work remains.

Every input kind uses the same identity for admission, membership, and cancel.
This operation never interrupts a later unrelated turn. Repeating it reports
the current outcome of the same input, without resubmitting that input.

`POST /sessions/{session_id}/interrupt` requires `run_id`, nullable, and
`through_input_order`, taken from the session snapshot. It cancels still-waiting
inputs at or below that order and requests interruption of exactly that run.
Newer queued inputs remain accepted. An already ended run is reported as ended;
a later run is never interrupted by retrying this request. Acceptance of an
interrupt request does not mean all external tools stopped.

The result contains `run_id`, `state: "requested"|"already_ended"`,
`cancelled_input_ids`, and warnings. Interruption prevents new inputs joining
the captured run. Live status reports `interrupting` until the run ends.

## History, context, catalogs, and runtime

### Durable history

`GET /sessions/{session_id}/history` accepts `view=entries|checkpoints`, default
entries, and one of `before`, `after`, or `next`. Positions are durable
transcript positions, unrelated to the actor cursor. Pages retain ascending
display order and include `older`, `newer`, and `high_water`.
Default entry count is 100, maximum 200, with a 256 KiB content budget.

Each entry has stable `id`, `position`, `kind`, `turn_id`, `input_id`,
`created_at`, `content`, nullable `checkpoint_id`, and `content_complete`.
User entries, assistant answers, and tool calls expose checkpoints for their inclusive durable
transcript row. Calls packed into one row share a checkpoint; a fork cannot
split that row. Checkpoint view lists user turns for the TUI fork picker.
Recorded thinking duration is exposed as `thinking_duration_ms`; live thinking
completion can report `elapsed_ms`. These measure thinking, not the whole turn.

Kinds are `user`, `assistant`, `thinking`, `tool_call`, `tool_result`, `note`,
`continuation`, `compaction`, and `image_fit`. Content is a tagged set of text,
JSON tool arguments or results, image metadata, and execution trace fields.
Tagged daemon notes retain their native origin as a JSON part with `field: "origin"`.
Tool names, native call IDs, normalized progress-call IDs, activity summaries,
and file diffs remain available. Provider-private fields are explicit opaque
data; clients do not reinterpret them as execution instructions.

The daemon pages on complete display groups when they fit. A large group uses
content references rather than growing a response past its bound. Preview
truncation is explicit and never changes the stored content. Checkpoint view
contains position, valid checkpoint ID, title, turn type, and bounded preview.
It provides the TUI tree and fork picker without a separate tree route.

`GET /sessions/{session_id}/history/{entry_id}` returns the full entry content
as pages of `parts`, each with `field`, `offset_bytes`, `text`, and `complete`.
Text and JSON fields use their exact stored UTF-8 encoding; offsets are bytes,
and pieces end on UTF-8 boundaries. Opaque `next` identifies the next piece.
Binary image parts use base64 with decoded-byte offsets. The decoded content
budget is 256 KiB per page. The daemon shortens a page further when JSON escaping
or base64 would reach the common encoded response bound.
Metadata identifies MIME type, dimensions, and original byte count. Clients
can reconstruct full arguments, results, and images without filesystem access.

### Prepared context and request records

`GET /sessions/{session_id}/context` defaults to `view=summary`. It describes
the latest actual prepared request, never prepares a new one. The summary has
`state: "pending"|"ready"`, nullable `snapshot_id`, capture time, provider,
model, protocol, context-window tokens, compaction observations, and sections.
Each section contains ID, label, kind, source, item count, UTF-8 byte count,
page count, and bounded preview. Pending state contains a reason.

`view=section` requires `snapshot_id`, `section_id`, and a zero-based `page`.
A page has `text`, omitted-content explanation, page index, and page count.
Text has a 32 KiB UTF-8 limit and ends on a character boundary. Only the latest
snapshot is retained. If it changes during navigation, the old identity returns
`410 context_changed`; the client refreshes the summary. A page never silently
comes from another prepared request.

`view=requests` returns paged provider request records. `after` is a durable
record sequence. Records include provider profile and account labels, model,
nullable run identity, timestamps, request kind, outcome, HTTP status, token
observations including reasoning and cache writes by TTL, cache marks, head and
projection hashes, input counts, compaction strategy, bounded safe failure
details, and links to source transcript positions. Unknown historical run
identity is null. Full provider request bodies and credentials are absent.
Estimated and observed token counts have separate fields and sources.

`GET /models?view=cache-policy` reads the cache-policy table and its layer
diagnostics. Entries retain matching patterns, clock, tiers, prices, survival,
evidence, sources, and notes. `limit` and `next` page entries. Optional
`extension`, `host`, and `model` selectors return the first matching entry in
`matched`, independent of the displayed page. This view does not require a
provider profile and never connects to a provider. Catalogue view remains the
default.

### Discovery and loaded composition

`GET /sessions/{session_id}/catalog` returns `discovery` and `loaded` as
separate fields. Optional `kind=extensions|skills|instructions|mcp|commands`
filters entries without changing these identities. Discovery contains
`revision`, workspace, candidates, and diagnostics. It reflects current local files
and preferences. Remote files come from the last observed mirror; preparation
refreshes stale mirrors. Loaded contains its composition revision and prepared command
definitions. Reading discovery does not reload the prompt or start a kernel.
Before a composition exists, `native_commands` supplies static HTTP declarations
from selected extensions. Clients use these declarations only while the loaded
revision is null; observing them does not prepare an extension or start a kernel.
If desired discovery fails, `discovery` is null and `discovery_failure` contains
a safe reason. Retained loaded commands remain readable. Successful discovery
sets `discovery_failure` to null; clients need a discovery revision to edit selection.

Candidates contain `id`, `kind`, `title`, `description`, lexical `source`,
nullable `resolved_source`, `preference_key`, `valid`, `eligible`,
`effective_enabled`, nullable global preference and session override,
`shadowed_by`, dependencies, quarantine state, and diagnostic. Extension candidates
also include typed context, tool, Python module, and plugin metadata for inspection.
Other candidate kinds return `extension: null`.
Selections use candidate IDs and the observed discovery revision. Paths are
daemon metadata, not client filesystem instructions. Diagnostics survive
missing, invalid, shadowed, and quarantined entries.

Command definitions contain ID, slash name, description, typed argument
declarations, caller permissions, and `delivery: "read"|"mutation"|"input"`.
They identify either a canonical HTTP operation or a durable input variant.
There is no public endpoint that accepts an arbitrary slash command string.
The CLI parses slash syntax into the named operation; Python bindings call
the same domain owner with trusted model caller context.

Optional page descriptors contain title, empty-state text, rows, glance,
and actions. Rows include ID, text, badge, tone, detail, and the observed
resource URL and `etag` for an editable item. Actions declare
label, optional keyboard hint, confirmation text, HTTP method, relative path
template, typed path, query, body, and header bindings, and result schema.
Path, query, and header binding keys name declared parameters. Body binding
keys are JSON pointers into the request object; they also support nested fields.
Bindings read a literal, the displayed row, submitted form, or installed session
snapshot. Form fields can declare `default_binding` with a `row` or `session`
source and JSON pointer to prefill an edit. The resolved value replaces the
literal default and must fit the declared field type. Missing optional form values omit their bindings. Result schemas
are JSON Schema 2020-12 fragments, without remote schema retrieval.
An operation can declare `success_status` as 200 or 201. Without it, reads
require 200 and mutations accept 200 or 201; acknowledgment validation still
applies.
An edit binds `If-Match` to the row's observed validator. The adapter never
fetches a newer validator just to overwrite data from a stale screen.
Field types are text, secret,
boolean, choice, integer, or hidden literal. Descriptors cannot change retry
policy or authorization. The adapter rejects foreign origins and undeclared
extension routes. Extension-specific response content stays an explicit
dynamic JSON body, such as `json.RawMessage` in Go.

### Reload, kernel upgrade, and compaction

`POST /sessions/{session_id}/reload` accepts
`target: "session"|"models"|"both"`, default both. Session reload requires idle,
builds the candidate composition before swapping it, and retains the previous
composition on failure. Success preserves the Python namespace and pinned
prompt prefix, except where an extension's declared lifecycle requires restart.
The result includes loaded revision, restart requirements, and warnings.
Model reload reports success or failure per provider and keeps old catalog
data where refresh failed. It also reloads cache policy, reported separately as
`cache_policy` with state and failure; session-only reload returns null there.
`both` returns these outcomes explicitly; one
confirmed refresh is not hidden by failure of the other.

`POST /sessions/{session_id}/kernel/upgrade` accepts an empty object and requires
idle. It stages the new kernel, reports the fate of live jobs, copies supported
namespace state, and swaps only after validation. Failure keeps the previous
kernel usable where the existing upgrade boundary permits it; stopped external
jobs are reported as stopped and cannot be claimed restored. The response
contains old and new identities, upgrade state, stopped jobs, and warnings.

`POST /sessions/{session_id}/compaction` accepts an optional `strategy`. It
requires idle and compacts the model-facing projection without deleting
transcript history. A supplied strategy first becomes the session override.
The response reports `selection_applied`, the effective strategy, compaction
state, before and after counts, and safe failure details. A failed compaction
can retain a successfully selected strategy; the response preserves that fact.
Neither runtime action automatically retries an uncertain external effect.

## Models, workspaces, hosts, and provider login

`GET /models` requires `provider_profile`, or `provider` with optional
`endpoint` for a not-yet-saved profile. It always returns model objects,
never a mode-dependent array of plain IDs. Objects contain ID, label, effort
choices, default and effective context tokens, nullable maximum context and
output tokens, input modalities, image edge, raised state, and cache policy.
Unknown facts are nullable. Optional `model` returns a single metadata row
for a requested ID, including an unlisted manual ID and its `cap_key`.
Manual IDs remain accepted when the provider cannot enumerate them.
Metadata includes source and freshness.

`GET /workspaces` without `location` lists recent canonical workspaces with
use counts and last activity. With `location`, it returns `directory`, child
directories, canonical parent, home, host state, and pagination. `include=preview`
adds repository facts, language shares, and a bounded two-level file tree.
Git and jj facts retain their distinct typed variants. A missing optional VCS
fact is null with a diagnostic, rather than loss of the entire directory.
The tree has at most 12 top-level entries and four children per directory;
`more` counts omissions. Local and SSH locations share this representation.
Paths are interpreted and canonicalized on the daemon's host.

`GET /hosts` returns known SSH targets and cached state, optionally filtered by
`target`. State is `unknown`, `probing`, `ready`, `needs_auth`, `unreachable`,
or `unsupported`, with safe detail, observation time, OS, architecture, home,
and nullable authentication instructions. `POST /hosts/{host}/probe` starts
or joins one bounded probe and returns `202` with the host state. Repeated
probe requests coalesce. GET does not start SSH sign-in.

SSH sign-in remains an explicit operator action. A local CLI can perform the
existing terminal handoff using daemon-supplied target and control-path
metadata after confirmation. A client on another machine displays instructions
for signing in on the daemon host. This API does not promise a browser terminal.
Filesystem failure codes distinguish missing workspace, needs-auth,
unreachable host, unsupported host, and permission denied.

`GET /auth` returns login providers, their form fields and supported flows,
redacted accounts, and account selection metadata. It does not duplicate
credential values from settings. `PUT /auth/logins/{login_id}` uses UUIDv7,
with provider and declared typed form values.
The server records immutable login intent and returns URL, expiry,
`state`, and manual-input instructions. First creation returns `201`;
an identical PUT returns the existing flow with `200`. Changed intent returns
`409 login_conflict`. Same-ID comparison stays inside the daemon and includes
the private form values. A duplicate never starts a second flow.
Login secrets never appear in the read representation or its fingerprint
provenance fields. Fingerprints are server-created and are not exposed for
low-entropy login secrets.

GET inspects that flow. `PATCH` supplies `response`, such as a pasted callback
URL or provider code, under `If-Match`. DELETE cancels it idempotently. States
are `waiting`, `exchanging`, `complete`, `failed`, `cancelled`, and `expired`.
Flow reads include bounded safe progress and globally unique opaque account
IDs that also identify their provider. Completed flows
return account metadata. Terminal flow metadata remains for 15 minutes,
uncompleted flows expire after their advertised provider deadline, and at
most eight flows are active. Duplicate creation never opens a second flow.
An expired or evicted ID cannot restart a flow. Unknown IDs older than the
15-minute flow recovery window return `410`.

Login admission intent and terminal decisions survive daemon restart within
their retention window. A restart marks an unfinished flow `failed` with
`code: "daemon_restarted"`; it does not reuse a lost listener or exchange.
Repeating its PUT returns that retained failure. Starting again requires a
new login ID. The daemon retains only the protected secret material needed
for immutable-intent comparison and removes it when the record expires.

OAuth callbacks stay on provider-required daemon-owned loopback listeners.
They validate provider state and PKCE where the provider supports it. Manual
callback input preserves remote-client usability. Secrets and callback codes
stay out of logs and SSE. Selecting an account updates a provider profile
through `/settings`; `DELETE /auth/accounts/{account_id}` refuses removal
while a saved profile still references it. It does not interrupt a running
request using captured credentials.

## SSE delivery and recovery

### Session watch

`GET /sessions/{session_id}` with `Accept: text/event-stream` watches one
session. Initial attachment omits `after_generation` and `after_seq`.
Reconnect sends both from the last fully consumed batch. `tail` applies when
a snapshot is needed. JSON reads return the same cursor pair for subsequent
attachment. `Vary: Accept` distinguishes the representations.
A successfully installed JSON session snapshot counts as the initial reset.
Its cursor can seed the SSE watch after the snapshot callback succeeds.
Without an installed snapshot, the client omits the cursor and requires reset.

A batch uses this envelope. `snapshot` appears only with a leading reset.

```json
{
	"generation": "J6kYj6IGcXyP3eMIp-WL3A",
	"cursor": 42,
	"events": [
		{"type": "reset", "data": {"reason": "initial"}}
	],
	"snapshot": {
		"id": "019a0000-0000-7000-8000-000000000001",
		"history": {"items": [], "older": null, "newer": null, "high_water": 0},
		"current_progress": [],
		"pending_inputs": []
	}
}
```

The example shows the relevant snapshot fields; a real snapshot is the complete
`Session` representation defined above. Generation is a nonempty base64url
128-bit random identity created by the session actor initializer. Sequence is
a nonnegative integer in that generation. Empty keepalive batches carry both
values and an empty events array. Keepalives do not advance the event sequence.
The `data:` JSON is authoritative; this protocol does not use SSE `id` or
automatic `Last-Event-ID` recovery.

The session checks generation equality before consulting numeric replay
bounds. Missing or different generation, or an unavailable sequence, requires
a durable snapshot reset. Malformed cursor components return `400` before
headers. A well-formed future or evicted cursor resets. The replay buffer
retains at most 256 events or 4 MiB, whichever bound is reached first.
An oversized event is represented by bounded history references.

Registration and state capture serialize with session publication. A reset
captures state, bounded current progress, pending ownership, and replay cursor
together, then loads history through the captured durable high-water mark.
Capture publishes any pending coalesced progress or activity before choosing
the cursor. Live-state changes advance the actor sequence; one cursor cannot
identify conflicting status, progress, or activity replacements.
Events after that cursor remain eligible for replay. Slow snapshot loading
cannot silently skip an evicted interval: the subscription resets again or
closes with failure. Transcript loading failure emits failure and closes;
it never installs a successful replacement cursor.

Client delivery follows these rules:

1. Validate the complete batch, generation, sequence, and known event fields.
2. Require a leading reset on first attachment or a generation change.
3. On reset, replace visible recent history, pending state, and live progress.
   Clear partial arguments and transient text from the previous stream.
4. Deliver all events in order. Same-generation replay cannot regress the
   sequence without a reset.
5. Save generation and sequence together only after every callback succeeds.

EOF and transient failures retain the last consumed pair. Explicit recovery
and cancellation clear it. A generation change with reset is ordinary recovery.
A change without reset is a protocol failure. The client can attempt one
cursor-free recovery; a second protocol failure is surfaced to the user.
Reset history is authoritative for its covered window. Previously loaded older
history remains accessible by durable positions and is deduplicated by entry ID.
Reset replaces daemon-derived views. It preserves local drafts and unresolved
creation or input handles, reconciling them only by matching identities.

### Session events and progress

Each event has `type` and `data`, its typed body. A published session event
also has `sequence`, its position in the generation. Control events reset and
failure have no sequence. Session identity is implicit in the
subscribed URL. Events within a batch are ordered. There is no ordering claim
between streams belonging to different sessions. A failure control appears
alone, without a snapshot, and terminates the stream even before attachment
has succeeded. Clients never treat it as a successful reset.

For example, an incremental batch appends text:

```json
{
	"generation": "J6kYj6IGcXyP3eMIp-WL3A",
	"cursor": 43,
	"events": [
		{
			"type": "text",
			"sequence": 43,
			"data": {"run_id": "run-1", "message_id": "message-1", "text": "Hello"}
		}
	]
}
```

Incremental event sequences increase contiguously from the requested cursor.
The batch cursor is the last published event represented by the batch. Clients
apply a batch atomically to local state or deduplicate already delivered events
by generation and sequence. This prevents duplication when an earlier callback
succeeds and a later callback fails before the batch cursor is saved.

| Type | Body and behavior |
| --- | --- |
| `reset` | Reason `initial`, `generation_changed`, `replay_unavailable`, or `recovery`; requires the complete batch snapshot. |
| `status` | Current phase, run ID, interrupt state, and blocking reason. |
| `input` | `input`, a bounded `Input` outcome update, including membership and delivery changes. |
| `text` | Run ID, message ID, and appended assistant text. |
| `thinking` | Run ID, message ID, and appended reasoning text. |
| `message` | Completed display message with stable history entry identity. |
| `tool_progress` | `progress`, a normalized progress object, or null to clear all live progress. |
| `tool` | Completed call identity, progress identity, bounded arguments, result, trace, and full-content reference if needed. |
| `note` | Entry identity, origin, display text, and related family mail IDs where present. |
| `retry` | Run, provider attempt, safe reason, and retry delay in milliseconds; clears obsolete attempt progress. |
| `usage` | Typed token, timing, model-window, and cache observations. |
| `committed` | Durable high-water position that covers previously displayed events. |
| `turn_completed` | Run ID, terminal outcome, and input membership. |
| `compacted` | Strategy and observation, without replacing durable history. |
| `error` | Safe error code and message for the turn; not transport authentication. |
| `invalidate` | Resource kind and relative URL whose metadata changed. |
| `failure` | Stream error code; terminal, never advances the saved cursor. |

Assistant text and reasoning are provisional until committed. Clients reconcile
completed entries by stable identity. Model retry can end an attempt without
creating another user input. Family mail events are durable notes with nullable
`mail: { "mail_id": ..., "sender_session_id": ..., "receiver_session_id": ...,
"kind": ..., "bytes": ... }`. Sender is null for external senders.
Kind is `task`, `message`, `result`, `unreviewed`, or `webhook`; bytes count
the UTF-8 message body. `unreviewed` is an answer forwarded after a child ended
without replying. A null sender also includes a bounded `sender_label`, such
as a hook name, at most 100 Unicode scalar values and 400 UTF-8 bytes.
The agent view animates these identities without interpreting note text.

Progress contains `call_id`, nullable `tool_call_id`, `name`, `phase`,
`intent`, and optional `preview: { "offset_scalars": ..., "text": ... }`.
Phase is `generating` or `running`. Intent is `read`, `search`, `list`, `run`,
or `unknown`; unknown remains valid. Intent comes from declared tool metadata
or emitted execution evidence; generating code can have unknown intent.
The daemon does not parse Python just to guess a label.
The client does not accumulate arguments or infer Python
behavior. Calls interleave by `call_id`, which changes across actor lifetimes,
runs, provider steps, retries, and output indexes.

Preview updates replace the latest window. The window has at most 512 decoded
Unicode scalar values and 2,048 UTF-8 bytes. `offset_scalars` counts decoded
source scalars before that window, including source newlines. It does not count
JSON escapes, UTF-8 bytes, grapheme clusters, or terminal columns. Names have
a 100-byte UTF-8 bound; native IDs over 200 bytes are omitted. One progress
event has an 8 KiB bound and an attempt tracks at most 32 calls. Excess calls
disable generating previews for that attempt while execution continues.

First appearance and transition to running publish immediately. Other preview
updates coalesce over 100 ms. Attachment captures updates awaiting publication.
Completion, cancellation, failure, retry, and reset clear obsolete previews.
Argument parsing occurs once per provider fragment, before subscriber delivery.
Full tool arguments and results remain durable. Capability `tool_progress: 1`
is required; there is no legacy client reconstruction.

### Collection watch and overload

`GET /sessions` with `Accept: text/event-stream` uses the same scope filters as
the JSON collection, excluding pagination and sort. It sends invalidations,
not transcripts or duplicate full argument payloads. Its first batch contains
`ready` and `reset`, requiring an authoritative collection read. No cursor
or replay promise applies to this stream.

```json
{
	"events": [
		{"type": "ready", "data": {}},
		{"type": "reset", "data": {"reason": "initial"}}
	]
}
```

An incremental batch contains `invalidate` events with resource URLs and
affected session IDs, plus bounded `activity` replacements for visible agents.
An activity event has this typed body:

```json
{
	"type": "activity",
	"data": {
		"session_id": "session-1",
		"cursor": {"generation": "J6kYj6IGcXyP3eMIp-WL3A", "sequence": 10},
		"status": {"phase": "idle", "run_id": null, "interrupt_requested": false, "blocking_reason": null},
		"current_progress": [],
		"activity": {
			"lines": [],
			"output_scalars": 0,
			"output_utf8_bytes": 0,
			"observed_at": "2026-10-02T14:00:00Z",
			"latest_input": null,
			"latest_answer": null
		}
	}
}
```

Status, current progress, activity, and cursor are captured together and replace
the row's live state together. The cursor matches the summary cursor. Separate
updates cannot share a cursor while replacing only one of those fields.
Collection `mail` events carry the same mail metadata as session notes, without
message text. Peer labels come from session summaries; unknown peer IDs trigger
a metadata read. These animation events have no replay guarantee.
Scope filters cover both entry and removal, including a
workspace change moving a row out of the filter. The daemon invalidates the
scope when it cannot resolve membership cheaply or safely.

A client subscribes, waits for ready, then reads authoritative JSON pages.
Changes during loading leave the view dirty and cause another refresh.
Activity replacements arriving during that read are applied afterward by
their per-session generation and sequence. Equal or older sequences cannot
overwrite a newer row. An actor-generation mismatch requires refreshing that row.
This yields a current view without claiming an atomic snapshot across actors.
Reconnect always repeats the readiness and refresh flow.

The bus queue holds at most 256 events and 1 MiB per subscriber. Mailboxes carry
at most one outstanding wake, never full payloads. Publication uses bounded
nonblocking admission. Session streams read the existing replay buffer rather
than maintaining additional payload queues. Flushes coalesce over 100 ms.
Progress and display events have independent payload bounds.

At overflow, the collection stream emits `overflow` and closes if the socket
can still accept the signal. Closure alone also requires refresh; delivery of
the final marker cannot be guaranteed to a stalled reader. The client refreshes
by resubscribing, waiting for ready, and then reading the authoritative tree,
status, progress, and glances. It does not append new state to an obsolete graph.
Disconnect and failed writes release the subscription and its queue.

Both stream kinds send keepalives at least every five seconds when quiet.
Sockets have bounded write waits. Publication never awaits subscriber socket
writes. A stalled reader cannot retain an unbounded mailbox or force another
subscriber's writes to wait behind its own. Reverse proxies must pass streaming
responses without buffering. Compression is disabled by default. History, images, and
large extension results remain bounded HTTP reads, not unsolicited stream data.

## Extension contracts

Extension management stays under `/extensions/{extension_name}`. These routes
are not aliases for core commands. The extension owns validation, persistence,
permissions, and typed domain results. Enabled routes and action descriptors
are discoverable through the server and session catalog.

HTTP bearer clients are human operators. Internal model callers use the same
domain operations with trusted caller context supplied by the runtime.
A JSON `role`, `caller`, or session ID cannot grant human permission.
Core shutdown and global credential management cannot be delegated through a
page descriptor. Disabling a service returns `404` for its HTTP routes.

Extension lists use common pagination and may include optional `page` and
`glance` render hints. Each editable row includes `resource`, containing URL,
value, and its observed `etag`. Work, paperclip, and schedule item reads are
canonical item representations. Hook and linked-group reads include runtime
observations and expose a separate `view=configuration` resource for edits,
using the session configuration convention. Its validator covers only the
complete configuration representation, not changing runtime observations.

Mutation responses contain `resource` and `notification`. Notification has
`state: "not_requested"|"queued"|"failed"`, with nullable safe `code` and
`detail`. Multiple targets use `notifications`, one result per target.
Creates return `201` with `Location`; edits return `200`. Deletes return `200`
when reporting a deleted resource or notification outcome, otherwise `204`.
A committed ledger edit remains successful if notifying an agent fails.
Secret-generating POSTs have no automatic retry after response loss; the caller
reads the resource and explicitly rotates if the secret was lost.

### Work

| Path | Methods |
| --- | --- |
| `/extensions/work/items` | GET, POST |
| `/extensions/work/items/{item_id}` | GET, PATCH, DELETE |

Every Work read and mutation requires a `workspace` query selecting the invoking
workspace. GET collection reads its linked group. POST accepts
`title`, optional `notes`, `parent_id`, `session_id`, and `run_id`.
Fields include those values, `status`, `revision`, and timestamps. Status is
`open`, `active`, `blocked`, `done`, or `cancelled`. A run requires a session.
PATCH changes title, notes, status, session, or run under `If-Match`; parent
and original workspace are immutable. The query supplies the creation workspace;
notes default to empty, status defaults to open, and optional IDs default to null.
Title has a 4,096-byte limit; notes have a 32 KiB limit. DELETE requires
`If-Match` and rejects an item with children.
Writes remain scoped to the invoking workspace's linked group.

Human mutations can name `notify_session_id` to queue the existing user-change
note. Results distinguish ledger commit from note delivery. Models retain
their workspace-scoped create, read, update, and delete operations through
trusted internal bindings. Work pages preserve linked-workspace labels and
pending-work glances.

### Paperclips

| Path | Methods |
| --- | --- |
| `/extensions/paperclips/items` | GET, POST |
| `/extensions/paperclips/items/{item_id}` | GET, PATCH, DELETE |

This ledger is global. Items contain ID, topic, title, message, suggestion,
reply, status, origin session and workspace, creation time, resolution, and
resolving session. Topic is `harness`, `workflow`, `bug`, `user`, or `other`.
POST accepts topic, message, optional title and suggestion, and the filing
session and workspace. Topic defaults to other; optional text defaults to empty.
Message is nonblank and at most 32 KiB; title is at most 4 KiB; suggestion,
reply, and resolution are at most 16 KiB each. Topic, title, message, suggestion,
and origin are immutable after creation. Status, timestamps, and resolving
session are response-only at creation.

Humans PATCH status to `acknowledged`, `resolved`, or `dismissed`, or supply
`reply`. A reply acknowledges the item and attempts a note to its filing session.
The reply stays saved when notification fails. DELETE removes the item.
PATCH with reply cannot also set resolved or dismissed. Human resolution can
include a resolution note; it never changes the original message. A model's
resolving session comes from trusted runtime context. DELETE requires `If-Match`.
Models can file, list, and resolve still-open or acknowledged items with a
nonempty resolution. Human terminal decisions cannot be overwritten by a model.
All edits use `If-Match`. Listings use newest-first cursor order and global glances.

### Schedule

| Path | Methods |
| --- | --- |
| `/extensions/schedule/jobs` | GET, POST |
| `/extensions/schedule/jobs/{job_id}` | GET, PATCH, DELETE |

GET requires `session_id`. POST accepts session ID, kind, prompt, and
`delay_seconds`, with `every_seconds` required for recurring or heartbeat jobs.
Kinds are `once`, `recurring`, and `heartbeat`. Prompt has a 4,096-byte limit;
intervals range from 60 to 31,536,000 seconds. Resources include `next_at`.
PATCH can change `prompt`, `kind`, `delay_seconds`, and `every_seconds` under
`If-Match`, preserving once-to-recurring edits. Once jobs prohibit repetition;
recurring and heartbeat jobs require it. A prompt-only edit preserves `next_at`.
A changed delay resolves from commit time. DELETE requires `If-Match`.
Models retain these operations.

Once jobs disappear after durable delivery. Recurring prompts queue behind
running work. Heartbeats skip busy sessions. Restart resumes the schedule
without replaying every missed interval. Session deletion removes its jobs.

### Linked workspaces

| Path | Methods |
| --- | --- |
| `/extensions/links/groups` | GET, POST, DELETE |

GET requires `workspace` and returns its complete group with bounded remote
presence facts, paged where necessary. Configuration view contains membership
and revision without remote presence facts. POST uses that observed configuration
URL and its `If-Match`, with `other_workspace` and `other_etag` from the other
group's configuration read. It checks both groups and merges them in one owner
commit. Stale membership on either side returns `412`.
DELETE uses the configuration URL plus `member` and checks that member belongs
to the observed group at commit. The member becomes its own group. Neither operation deletes work
or memory. Writes are human-only. Notifications to affected open sessions
are reported separately from the committed group change. `notification_count`
covers all targets; the response includes up to 200 outcomes and `truncated`
when the list reaches its count or byte bound.

### Webhooks

| Path | Methods | Authentication |
| --- | --- | --- |
| `/extensions/webhooks/hooks` | GET, POST | Daemon bearer |
| `/extensions/webhooks/hooks/{hook_id}` | GET, PATCH, DELETE | Daemon bearer |
| `/extensions/webhooks/hooks/{hook_id}/secret` | POST | Daemon bearer |
| `/extensions/webhooks/hooks/{hook_id}/deliveries` | GET | Daemon bearer |
| `/extensions/webhooks/hooks/{hook_id}/deliveries` | POST | Signature over raw body |
| `/extensions/webhooks/deliveries/{delivery_id}` | GET | Daemon bearer |
| `/extensions/webhooks/permissions/{session_id}` | GET, PATCH | Daemon bearer |

Hooks contain ID, name, target session, enabled state, signature header and
prefix, revision, public delivery URL, pending delivery count, and latest
deferral reason. Names use 1 to 64 ASCII letters, digits, `_`, or `-`.
POST accepts `session_id`, `name`, optional `enabled`, `signature_header`,
`signature_prefix`, and `secret` of 16 to 4,096 bytes. Name is unique within its
target session. Enabled defaults true. Header uses 1 to 64 ASCII letters, digits,
or hyphens; prefix has at most 32 bytes and no CR or LF. Absence generates a secret.
PATCH configuration accepts name, enabled, header, and prefix. Target session
is immutable. ID, revision, URL, pending counts, and diagnostics are read-only.
Secret rotation POST accepts only an optional secret. Creation and rotation return that
secret only in the operation response. Rotation and PATCH require `If-Match`.
Stored secrets never appear in lists, descriptors, ordinary logs, or SSE.

Permission reads return false when no setting exists. PATCH accepts explicit
`agent_manage`, with omission retaining its value. Only humans grant it.
Agent management remains restricted to that agent's target session. Turning
management off does not disable hooks or prevent reading that session's own
accepted delivery payloads. Hook edits use the caller's observed revision,
not a revision fetched just before overwriting a stale screen.

Incoming delivery POST has a 65,536-byte raw-body limit. It requires the
configured HMAC-SHA256 signature and never accepts a bearer token instead.
Default header is `X-Albedo-Signature` and prefix is `sha256=`.
Missing or invalid signatures return `403`, without a daemon bearer challenge.
Optional `X-Albedo-Event-Id`, at most 128 bytes without newlines, deduplicates
by hook, ID, and body hash. A changed body under that ID returns `409`.
Acceptance stores the delivery and its durable inbox entry together, then
returns `202` with `delivery_id`. A full target inbox returns `429`;
unknown or disabled hooks return `404`. The pending bound is 1,000 per session.

Delivery lists accept `state=pending|delivered|all`, default all, and common
pagination. Metadata contains ID, hook ID, target session, receipt and delivery
timestamps, attempts, and latest deferral reason. Direct delivery reads add
`payload: { "encoding": "utf8"|"base64", "data": ... }`.
Both direct and by-hook historical reads remain available after hook deletion.
Payloads are external data and carry no instruction authority. Deleting a
hook retains accepted deliveries. Deleting the target session removes its
hooks and inbox. An operator exposing intake through a reverse proxy allows
only the signed POST method, not management GET on the same path.

### OpenAI proxy

| Path | Methods |
| --- | --- |
| `/extensions/proxy/v1/models` | GET |
| `/extensions/proxy/v1/chat/completions` | POST |

This optional service keeps its OpenAI-compatible request and response format,
including JSON and streaming responses. It is stateless with respect to agent
sessions: the caller supplies history. It retains the 32,000,000-byte request
limit and opaque provider state carried in tool IDs. The supported request
subset contains model, messages, tools, token limits, temperature, top_p, stop,
tool_choice, parallel_tool_calls, reasoning effort, response format, stream,
and stream_options.include_usage. User images must be base64 data URLs;
remote image URLs are not fetched. Unsupported fields return a proxy-format error.
Provider transports apply only options they can express, as described in
[the proxy transport contract](../robot-docs/proxy.md#translation).
Text and reasoning stream as delta.content and delta.reasoning_content.
Complete tool calls publish when the turn ends. Provider failure sends an error
chunk before termination, or a JSON error for a nonstreaming request.
The proxy's OpenAI envelope, field names, and body limit override platform
encoding conventions. It uses daemon bearer
authentication. An operator may explicitly enable anonymous loopback access;
that policy never grants access to core or other extension routes.

## Existing feature coverage

This table is the implementation acceptance checklist. UI shortcuts and labels
can stay unchanged while their adapter calls use the target contract.

| Existing feature | Target operation or data |
| --- | --- |
| Session picker, search, workspace filter, grouping, recent previews | Filtered session summaries with names, activity, workspace, preview, and shared preferences |
| Pinned, archived, and frequent sessions | Session preferences, `sort=frequent`, and identified visits |
| New session, checkpoint fork, child spawn | Session creation variants with retry provenance and atomic child task |
| Rename, stable family address, leaf or subtree deletion | Session PATCH, separate name and address, conditional deletion result |
| Text, images, continue, selected skill, queued steering | Immutable input variants and ordered durable admission |
| Pending rows, uncertain sends, uncertain creation across navigation | Same-resource decision lookup and retained original handles |
| Targeted cancel, shared turn, whole-turn interrupt | Input cancel and captured session interrupt |
| Chat, thinking, code preview, full tool output, file diffs | Session SSE plus durable history content reads |
| Late attachment, reconnect, restart, replay eviction | Actor-generation cursor and durable reset snapshot |
| Older history and transcript tree | Immutable history pages and checkpoint view |
| Footer status, usage, cache fade, context window | Session snapshot, status and usage events, model metadata |
| Model picker, manual ID, effort, default profile, raised cap | Session selection, models, and explicit separate settings changes |
| `/reload`, `/reload session`, `/reload models` | Typed reload targets with independent confirmed outcomes |
| `/compact [strategy]` | Compaction result preserving confirmed strategy choice |
| `/kernel`, `/kernel upgrade` | Session kernel metadata and explicit upgrade |
| Extensions, dependencies, quarantine, global defaults and inheritance | Fresh catalog, loaded composition, session overrides, shared settings |
| Skill and instruction discovery, source diagnostics, selection | Candidate revision checks and explicit resolved-source metadata |
| Context inspector and bounded section pages | Prepared snapshot identity and context section reads |
| Provider request telemetry | Context request-record view |
| MCP forms, credentials, validation and failed-save recovery | Atomic candidate settings patch with write-only secrets |
| Provider login, manual callback, choose or remove account | Auth flows, provider-profile selection, account deletion |
| `/cd`, folder and repository preview, missing workspace repair | Workspace read and family-aware session move |
| SSH host completion, probe, sign-in handoff | Hosts, explicit probe, and actionable local operator instructions |
| Agent graph, live tails and rate, attach, spawn, rename, delete, send, mail animation | Session family summaries, atomic activity replacements, normal input admission, typed mail metadata |
| Work, paperclips, schedule, linked-workspace pages and glances | Extension resources and declarative typed page actions |
| Webhook forms, copy URL, generated secret, rotation, permission toggle | Webhooks domain contract and one-time operation secrets |
| Shared thinking and tool display preferences | Settings UI group |
| Online storage report and offline diagnosis | Storage API and deliberate local diagnostic path |
| Ordinary CLI keep-or-restart offer | Existing launcher policy with instance-targeted shutdown |
| Drafts, editor, clipboard, mouse, animations, navigation, quit | Client-owned behavior; no daemon endpoint |

Agent-originated mail remains an extension/runtime operation under trusted
family permissions. Human graph messages use ordinary user inputs addressed
to the chosen session. The API does not let clients forge agent senders.

## Architecture and implementation boundaries

`server.gleam` owns routing, authentication, HTTP admission, negotiation, and
mapping domain errors to wire responses. It does not own session state or
execute extension commands inside a session actor.

The session actor owns generation, live status, normalized progress, replay
capture, and configuration application. The store owner commits identified
creation, pending input, consumption, and deletion outcomes on its transaction
connection. Family operations serialize membership validation with mutation.
The existing bus owns bounded collection notification admission and cleanup.

Settings owners validate and persist their desired state. Runtime composition
prepares candidates before applying them. Extensions keep their ledgers,
permissions, migrations, and handlers. Provider transport and Python RPCs stay
internal; their URLs and execution rules are not public client responsibilities.

The Go API adapter owns paths, query encoding, request and result types,
capability checks, byte bounds, deadlines, retry policy, and SSE validation.
Application commands and UI packages receive typed results and UI messages.
Local discovery and launching stay outside the connection. Other clients can
implement this contract without local storage or execution knowledge.

The implementation uses direct domain operations. It adds no forwarding-only
wrappers, generic command bus, generation registry, duplicate progress parser,
or per-client full-argument buffers. New route aliases require a contract
change, not a convenience helper in the UI.

## Verification

Behavioral tests exercise these outcomes through the real daemon:

- Lose creation and input responses, retry original IDs, edit a created session,
  and still recover the original intent. Reject changed intent and expired IDs.
- Retry a rejected queue-full input after capacity clears. It stays rejected.
  Delete its session and retain accepted, cancelled, and rejected decisions.
- Race child creation with interruption and deletion. No child lacks its task,
  and an old interrupt or deletion attempt cannot affect newer work.
- Attach during generation; replay, evict, restart the actor, and restart the
  daemon. Committed history survives and old numeric cursors never authorize replay.
- Interleave tool calls with escaped Unicode, retry, cancel, and transition to
  running. Progress remains bounded and full arguments remain in history.
- Stall one reader under sustained events from many agents. Measure queue bytes
  and mailbox length; another reader stays responsive, overflow refreshes, and
  disconnect releases subscriptions.
- Change collection membership while pages load. A removal or moved workspace
  reaches the client, stale activity cannot replace newer state, and reconnect
  refreshes graph, status, progress, tails, and glances without duplicate rows.
  Interleave text, tools, and mail across agents; one collection subscription
  preserves live tails and animation identities within the payload bounds.
- Page older history, retrieve a large tool result and image, and fork a valid
  checkpoint. Full content is recoverable and history navigation survives reset.
- Change prepared context between summary and page. The old page fails by
  identity rather than displaying another request's section.
- Race preference edits and stale catalog choices. Preconditions protect
  changes, false differs from omission, and null restores inheritance.
- Fail candidate MCP validation and session reload. Previous secrets and
  loaded composition remain usable; committed model changes remain visible
  when a later default or cap change fails. Reject conflicting credential
  sources before attempting a connection or changing saved settings.
- Exercise local and remote workspace browsing, missing workspaces, busy moves,
  descendant moves, and explicit SSH authentication instructions.
- Complete, cancel, and expire provider login flows, including manual callback.
  Restart during a flow; the old ID stays failed and cannot start another flow.
  Verify secret redaction, origin rejection, bearer failures, and browser CORS.
- Exercise work, paperclip reply, scheduling while busy, linked-group merge,
  webhook stale edits, signatures, deduplication, secret loss, and permissions.
  Committed domain changes survive a failed notification.
- Read storage from a client without daemon filesystem or Python access and
  compare known isolated totals. Attachment never starts or stops a daemon.

Controlled transport tests cover malformed wire data, callback failure before
cursor commit, partial HTTP responses, and failures a healthy daemon cannot
produce. Cross-cutting parser tests cover fragmented SSE lines and UTF-8 bounds.
There are no compatibility fixtures, UI copy snapshots, route-constant tests,
or tests that only encode and decode the same local type.

An independent consumer authenticates, creates a session, submits identified
input, watches SSE, resumes after disconnect, and reads history using only this
document. Its success verifies that Go-specific knowledge is not required.

Run focused E2Es and Go race tests for changed behavior, then `./test.sh` for
the complete gate. Review resource ownership, uncertain outcomes, bounded
queues, cleanup, and test failure modes when changing the API. Performance
experiments and their results belong outside the repository.

Server and clients use the same contract. Durable history and supported storage
migrations remain supported; old API wire formats do not.
