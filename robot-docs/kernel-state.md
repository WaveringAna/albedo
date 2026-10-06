# python kernel state

The Python kernel snapshots the session namespace into the session-owned state file. Plain values are serialized with dill when installed, otherwise pickle; each value is independent, so one unserializable value does not prevent other values from being saved. Loading runs in the same daemon-home/session trust domain as pickle and is not a security boundary.

## definitions from source

After a successful cell, the kernel records source for direct, top-level imports, functions, async functions, and classes. Decorators are included. Definitions nested inside `if`, `try`, `with`, or other compound statements are not captured. A later top-level assignment, delete, loop target, or with target removes a recorded name, so rebinding a function name to a value is not resurrected on restore. The latest definition wins.

On restore, pickled values load first, then definitions run in recorded order. Successfully restored definitions are registered again and saved on the next release. Definition source is authoritative when a name has both forms. A failing definition is reported and does not prevent later definitions. Definition replay has the same trust as pickle loading: it executes in the daemon home for this session.

## caps and reply contract

Pickled state is capped at 64 MiB total and 8 MiB per variable. The per-variable cap is enforced while serialising: the serialiser writes into a bounded sink that stops it past the cap, so a value too large to save costs the cap in time and memory, not its full size. Definition source is capped at 256 KiB total and 32 KiB per definition; over-cap entries appear in `skipped`. The snapshot/restore reply has a `state` object with existing `saved`, `restored`, `skipped`, `failed`, `engine`, and `error` fields. It may also contain:

- `defs`: names saved or restored by definition replay; these also occur in `saved`/`restored`.
- `largest`: up to five saved variables, biggest first, as `{"name": str, "bytes": int}`, only entries at least 64 KiB.

State files without `definitions` continue to load.

## expiry

A session's state file is deleted when the session has been idle longer than `ALBEDO_STATE_EXPIRY_SECONDS` (default 1209600, 14 days; range 1 to 31536000). Idle time is the session's last assistant reply, read fresh from the store at each sweep, not from the registry's cached copy. A session with no assistant reply yet is never expired. A session that later returns finds no saved state and gets the ordinary "kernel was reset" notice.

The same sweep deletes saved pastes (`$ALBEDO_HOME/pastes/<session>/<input>-<n>.md`, see `daemon/pastes.gleam`) whose file is older than the retention, whatever their session's activity.

The sweep runs once shortly after startup and then every `min(1 day, retention)` seconds, in its own process, never in a request or in the registry. A filesystem or store error ends that sweep quietly. It logs one line, `python state expiry: reclaimed N files (B bytes)`, when it deleted something.

Never deleted: the state of a session that holds a live kernel or is running a turn (a failed or timed-out status check counts as protected), and the state of any session the store knows about that is still inside its retention.

A state file that belongs to no session the store knows about is an orphan, and is deleted once it is more than a day old by modification time. Startup removes old orphans before sessions open.


`priv/python/albedo_state.py` owns serialization and definition capture.
`priv/python/albedo_cells.py` owns the live namespace and release/restore lifecycle.
