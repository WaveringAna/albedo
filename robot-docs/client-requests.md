# Client request recovery

The daemon owns admission and execution. Clients choose a retry policy for each operation through `Operation` and `RequestOperation`. An operation without a policy uses `NoRecovery`. The contract was reviewed against `23e4018861b9dbfcf56774995db3a1af01229283`.

| Policy | Operations | Automatic application recovery |
| --- | --- | --- |
| `ReadRecovery` | Audited core reads: health, settings, sessions, history, context, catalogs, status, authentication status, and stream establishment | At most one retry after a connection failure or a marked authentication refusal |
| `AuthRecovery` | Audited core mutations: submissions, session changes, commands, credentials, settings, and sign-in operations | At most one retry after a marked authentication refusal and changed connection credentials or address |
| `NoRecovery` | Shutdown, open-count increments, and unclassified extension operations | None |

HTTP method and a replayable body do not establish operation safety. A command that displays a page still uses the mutation policy because the shared command endpoint also executes actions. No mutation retries follow an ambiguous network failure, and this contract introduces no operation receipts or idempotency keys. Go's HTTP transport can independently reconnect a read-only GET on a reused connection; the client does not make audited mutations replayable.

## Admission and connection identity

Core routes reject invalid bearer credentials before dispatch with HTTP 403 and `code: "authentication_required"`. The same marker is available in `Albedo-Error-Code` for streams that inspect error status without reading a body. An Origin refusal does not carry either marker. Extension services have their own ingress and cannot inherit this core admission guarantee merely by returning 401 or 403.

Each attempt captures one immutable connection snapshot and derives both its address and bearer token from that value. Recovery retains the original operation context and payload. Refresh uses discovery and compatibility checks; it does not launch or replace a daemon. Failed refresh, unchanged address and token, and a second refusal return the rejection without another mutation attempt.

Read recovery covers connection failures, including failures while reading a bounded response body. A successful stream response ends establishment recovery: errors after consuming events return to the existing stream owner, without replaying delivered events.

## Uncertain results

`UncertainOutcomeError` means the mutation may have been accepted. It wraps the original cause, including cancellation and HTTP errors, for `errors.Is` and `errors.As`. It contains an operation label rather than credentials or submitted content. Losing the acknowledgement does not undo execution, and cancelling a request does not prove the daemon cancelled its work.

For a message, inspect the active conversation and its subsequent stream events before resending. For session creation, list sessions before creating another. For a command or settings change, read the affected state before repeating it. For sign-in, check the current login or accounts when its identity is available; a lost start response can leave an unknown flow that cannot be conclusively reconciled through the current API.

Clients preserve an uncertain pending submission for stream reconciliation and do not restore it as a definitely failed send. A definite local construction error or cancellation before dispatch remains an ordinary failure. Known authentication refusals remain rejections when recovery is unavailable. Acknowledgements describe the endpoint's existing acceptance or result contract, not a new durability guarantee.
