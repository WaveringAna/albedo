# session attachment

opening a session attaches the cli to its event stream and independently
reads `GET /sessions/:id/status`. replayed history does not establish the
session's live phase; status and live events do.

an idle status is enough to enable the composer, including a persisted
`interrupted` session after a daemon restart. a missing or unrecognized
phase is display metadata, not a failed connection. before live status is
known, enter preserves the draft; superseded status replies cannot unblock
it. starting a new turn does not require `/compact` to change the old phase.
