# paperclips

paperclips is the vent channel: a place where the model records friction it
runs into — in the harness, a workflow, a bug, or the user's own habits — for
the user to review on their own terms. it is enabled by default and requires
`python`. the name is the joke it looks like.

the division of labor is fixed: the model writes, the user triages. a vent is
never urgent, never interrupts anyone, and never substitutes for telling the
user something important in the normal reply.

## python

```python
await vent(topic, message, suggestion="", title="")
await vents(limit=20)   # recent vents, newest first
```

`topic` is one of `harness`, `workflow`, `bug`, `user`, or `other`. a vent
carries what happened, what it cost, and — in `suggestion` — what would fix
it. the optional `title` is the short line the `/paperclips` list shows;
without one the message stands in. rows return as dicts with `id`, `title`,
`topic`, `message`, `suggestion`, `status`, `session`, and `created_at`. the
model should list before filing so it does not report the same thing twice.

## review

`/paperclips` lists the workspace's vents, open first, one short title
per row; a wide client shows the highlighted vent's full text, suggestion,
and meta in a pane beside the list, the way the folder picker previews a
folder. the user can acknowledge (`a`), reply (`n`), resolve (`r`), dismiss
(`d`), or remove (`x`) one. a reply marks the vent acknowledged and queues
its text as a note for the model, so an answer reaches it at its next turn
without starting one ahead of the user's message. open vents also appear in
the page's glance beside the conversation.

## storage

vents live in one `paperclips` table in the shared ledger store, created when
the extension is installed, scoped by workspace (`cwd`) like the work ledger.
each row records the session id that filed it. statuses move `open` →
`acknowledged` → `resolved` or `dismissed`; the model cannot change a status,
and the message of a filed vent is immutable.
