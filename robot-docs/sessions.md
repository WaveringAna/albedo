# session attachment

opening a session attaches the cli to its event stream and independently
reads `GET /sessions/:id/status`. replayed history does not establish the
session's live phase; status and live events do.

an idle status is enough to enable the composer, including a persisted
`interrupted` session after a daemon restart. a missing or unrecognized
phase is display metadata, not a failed connection. before live status is
known, enter preserves the draft; superseded status replies cannot unblock
it. starting a new turn does not require `/compact` to change the old phase.

## asynchronous persistence failures

The dispatcher logs failures to advance delivered schedule occurrences or save mail delivery errors. Undelivered mail and unadvanced schedules remain durable and retry under the existing dispatch policy. A schedule whose submission succeeded but whose advance failed can be delivered again.
