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
await kid.close()                             # done: keep transcript + files, free the kernel
await agents.progress("on turn.gleam now")    # shows in /agents, starts no turn
```

- spawn never returns the child's answer: the answer arrives later as `<mail>` and starts the parent's next turn. a child whose turn ends without answering forwards its last message, marked `unreviewed`.
- names resolve inside the family (children, siblings, parent); anything else takes a session id.
- cancel and close work on your own children only. the model cannot delete an agent; it asks the user.
- limits: 3 deep, 12 open children per parent, 1 MiB per letter, 1000 undelivered letters per session.

## mail delivery

a letter is stored first and marked delivered in the same transaction that writes it into the recipient's transcript. an idle recipient starts a turn; a running one reads it at its next step. undelivered letters retry every 15 seconds, so a restart or a session that is not running yet loses nothing. webhook deliveries are letters from outside, and wait for an idle session.

## the orchestrator view

`ctrl+o` or `/agents` in a session shows its whole tree live: running agents pulse with their token rate, mail travels the edges as blocks. tab picks an agent, enter opens it (typing there is you, as the user), text + enter sends to it, `/spawn <name> <task>` starts a child under it.

routes: `GET /agents?session=<id>` (the tree), `GET /agents/stream` (batched events), `POST /sessions/:id/children`, `POST /sessions/:id/mail`.
