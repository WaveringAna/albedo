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
await kid.cancel(tree=True)                   # ...and the turns of everything beneath it
await agents.cancel_all()                     # every child and descendant (tree=True by default)
await kid.close()                             # done: keep messages + files, free the kernel
other = await agents.get("a1b2c3")            # "parent", a family name, or any session id
page = await other.messages(seq=0)            # page of its rows: content, next_offset
hits = await kid.search_messages("error")     # rows by seq, with previews
await agents.progress("on turn.gleam now")    # shows in /agents, starts no turn
```

- spawn never returns the child's answer: the answer arrives later as `<mail>` and starts the parent's next turn. a child whose turn ends without answering forwards its last message, marked `unreviewed`.
- names resolve inside the family (children, siblings, parent); anything else takes a session id.
- any session may look up and read any other: `get`, `messages`, and `search_messages` resolve names and ids the way mail does, and closed agents stay readable. cancel and close work on your own children only. `cancel(tree=True)` and `cancel_all()` stop parents before their children, so a stopped agent cannot answer by spawning, and answer the sessions that were running; they never close or delete anything. the model cannot delete an agent; it asks the user.
- limits: 3 deep, 12 open children per parent, 1 MiB per letter, 1000 undelivered letters per session.

## mail delivery

a letter is stored first and marked delivered in the same transaction that writes it into the recipient's transcript. an idle recipient starts a turn; a running one reads it at its next step. undelivered letters retry every 15 seconds, so a restart or a session that is not running yet loses nothing. webhook deliveries are letters from outside, and wait for an idle session.

## the orchestrator view

`ctrl+o` or `/agents` in a session shows its whole tree live: running agents pulse with their token rate, mail travels the edges as blocks. tab picks an agent, enter opens it (typing there is you, as the user), text + enter sends to it, `/spawn <name> <task>` starts a child under it.

The selected agent's card shows its status, latest delivered task or message
from its parent, and latest progress. Request and progress previews are bounded
to 512 characters. A new parent request clears the previous progress; peer mail
does not replace the request. Progress starts no turn and is replaced in place.
Idle means idle, including after restart; it does not imply the task is complete.
Narrow terminals show the card below the graph. Mail animation deduplicates IDs
with a bounded cache, while distinct messages with identical text remain visible.

The view reads `GET /sessions?scope=family&root_id={root_id}` and subscribes
to the same collection with `Accept: text/event-stream`. Child creation and
messages use the core session and input resources. The
[HTTP contract](../docs/http-api-design.md#collection-watch-and-overload)
defines activity replacements, mail animation metadata, and invalidations.

The Go adapter decodes known events before delivery. Malformed known events
fail the stream; unknown event kinds are ignored. The daemon supplies bounded
tool progress under `tool_progress: 1`. Clients render it without reconstructing
arguments or guessing Python intent.

## Stream overflow and refresh

The initial batch contains ready and reset controls. Subscriber byte and event
limits apply before payloads enter mailboxes; wakes are coalesced. Publication
does not wait for a client to read its socket.

Overflow discards queued deltas, emits an overflow control when the socket can
accept it, and closes the stream. The client resubscribes and refreshes the
authoritative family. That refresh replaces names, relationships, closed state,
status, and activity. Replies from an older attachment cannot repopulate the
view. Disconnect releases subscriber state without another publication.
Drafts and pending action results survive recovery. Terminal failures remain
visible; ctrl+l starts a fresh attachment.

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
busy swarm yields to the person at the machine. jobs never pause for admission,
and their deadlines count wall time after the program starts.

## deletion failures

Direct parent deletion requires a successful child lookup. Tree deletion collects the child-first walk before deleting any session. A failed lookup returns an error and leaves the sessions intact. A failure during deletion still reports how many sessions were already deleted.
