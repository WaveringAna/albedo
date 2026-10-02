# agents

a subagent is a session with a parent. a message is mail. both are daemon primitives; the `mail` and `agents` extensions (on by default) give the model its python surface.

## python

```python
m = await agents.models()                     # required once before spawning
kid = await agents.self.spawn("map every wake path", name="scout", model=m[0],
                              deliverable="notes/wakes.md")   # returns at once
await mail.submit(kid, "also cover schedules")               # or "parent", a name, a session id
kids = await agents.self.children()           # snapshots: running, closed
await kid.cancel()                            # stop its turn, keep everything
await kid.close()                             # done: keep messages + files, free the kernel
other = await agents.get("a1b2c3")            # "parent", a family name, or any session id
page = await other.messages(seq=0)            # page of its rows: content, next_offset
hits = await kid.search_messages("error")     # rows by seq, with previews
await agents.progress("on turn.gleam now")    # shows in /agents, starts no turn
```

- spawn never returns the child's answer: the answer arrives later as `<mail>` and starts the parent's next turn. a child whose turn ends without answering forwards its last message, marked `unreviewed`.
- names resolve inside the family (children, siblings, parent); anything else takes a session id.
- any session may look up and read any other: `get`, `messages`, and `search_messages` resolve names and ids the way mail does, and closed agents stay readable. cancel and close work on your own children only. the model cannot delete an agent; it asks the user.
- limits: 3 deep, 12 open children per parent, 1 MiB per letter, 1000 undelivered letters per session.

## mail delivery

a letter is stored first and marked delivered in the same transaction that writes it into the recipient's transcript. an idle recipient starts a turn; a running one reads it at its next step. undelivered letters retry every 15 seconds, so a restart or a session that is not running yet loses nothing. webhook deliveries are letters from outside, and wait for an idle session.

## the orchestrator view

`ctrl+o` or `/agents` in a session shows its whole tree live: running agents pulse with their token rate, mail travels the edges as blocks. tab picks an agent, enter opens it (typing there is you, as the user), text + enter sends to it, `/spawn <name> <task>` starts a child under it.

routes: `GET /agents?session=<id>` (the tree), `GET /agents/stream` (batched events), `POST /sessions/:id/children`, `POST /sessions/:id/mail`.

The Go client decodes known agent events into `daemon.AgentEvent` before delivery to the view. Unknown event kinds are ignored. Malformed known events return a protocol error instead of supplying empty fields to the view. Tool progress uses the same typed value as the session stream.

## Stream overflow and refresh

The agents stream sends an initial empty batch after subscribing. Each
subscriber retains at most 256 queued events or 1 MiB of encoded payload,
plus one bounded batch being sent. Event payloads stay outside subscriber
mailboxes, and wake notifications are coalesced. Publication never waits for
a client to read its socket.

When a subscriber exceeds either limit, the daemon discards queued deltas,
sends `{"events":[{"type":"overflow"}]}`, and closes the stream. An event larger
than the byte limit also causes overflow. A socket that remains stalled may
close before delivering the marker.

Overflow triggers a normal refresh. The CLI
clears unfinished previews, reconnects, and reloads the authoritative tree
after subscribing. The refreshed tree removes missing agents and replaces
names, parent relationships, closed state, and running status. Replies from
an older attachment cannot repopulate the view. Disconnecting releases the
subscriber's queue when its stream process stops, without waiting for another
publication. Drafts and pending action results survive recovery. Terminal
stream failures remain visible; `ctrl+l` starts a fresh attachment.

## swarm overhead

kernel boots queue behind four slots. each boot owns only its session's composition,
and each kernel's host callback captures only its routes, store handle, and session
id—not a snapshot of the other agents. run waits on process-exit notifications,
not periodic exit checks; descendant cleanup and deadlines still apply.

session replay retains at most 256 events or 4 mib, evicting incrementally rather
than copying the full window per token. missing events require a transcript reset.
the orchestrator feed batches every 100 ms and skips activity serialization when
nobody is watching.

run jobs start at once, at low priority (`nice`, and utility QoS on macOS), so a
busy swarm yields to the person at the machine. a job still running after the grace
window (5 s) is heavy and needs one of a few daemon-wide slots; without one it is
paused (`SIGSTOP`, `job.queued` is true) and resumed when one frees, so waiting
costs no cpu and loses no work. quick commands never wait. the timeout counts only
time the command ran. `await job.stop()` resumes a paused job so it can exit.

slots default to the machine's cores and shrink while the one-minute load average
runs past 1.25× the cores, which catches heavy jobs that fan out workers of their
own. a freed slot goes to the kernel holding the fewest, oldest request first, so
one busy agent cannot starve the rest. a slot is released only after process-group
cleanup is confirmed; failed cleanup keeps it held.

settings, read when the daemon starts: `ALBEDO_MAX_LOCAL_JOBS` fixes the slot count
(1–256), `ALBEDO_JOB_GRACE_SECONDS` sets the grace window, `ALBEDO_JOB_LOAD=0`
turns off the load adjustment. this bounds sustained shell work, not agent/model
concurrency, remote kernels, or python computed directly in a cell.

## deletion failures

Direct parent deletion requires a successful child lookup. Tree deletion collects the child-first walk before deleting any session. A failed lookup returns an error and leaves the sessions intact. A failure during deletion still reports how many sessions were already deleted.
