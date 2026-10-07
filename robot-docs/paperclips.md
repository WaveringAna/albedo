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
await resolve_vent(id, note)   # close a vent your change fixed
```

`topic` is one of `harness`, `workflow`, `bug`, `user`, or `other`. a vent
carries what happened, what it cost, and — in `suggestion` — what would fix
it. the optional `title` is the short line the `/paperclips` list shows;
without one the message stands in. rows return as dicts with `id`, `title`,
`topic`, `message`, `suggestion`, `reply`, `status`, `session`, `cwd`,
`created_at`, `resolution`, and `resolved_by`; `reply` carries the answer the
user left in /paperclips, if any. the model should list before filing so it
does not report the same thing twice.

`resolve_vent(id, note)` closes an open or acknowledged vent — any session's,
since the ledger is global — once a change fixed it. the note is required and
says what fixed it (a commit, a change); the row keeps it as `resolution` and
the closing session as `resolved_by`, and the detail pane shows both, so the
user can audit a closure instead of trusting it. a vent the user already
resolved or dismissed cannot be resolved again: the user's decisions stand.

## review

`/paperclips` lists vents from every session, open first, one short title
per row; a wide client shows the highlighted vent's full text, suggestion,
and meta in a pane beside the list, the way the folder picker previews a
folder. the user can acknowledge (`a`), reply (`n`), resolve (`r`), dismiss
(`d`), or remove (`x`) one. a reply is recorded on the vent — acknowledging
it — and queued as a note for the session that filed the vent, so an answer
reaches that model at its next turn without starting one ahead of the user's
message. the reply itself is durable either way: when the filing session is
gone, or a legacy vent records none, the triage answer says the model could
not be told and the reply stays saved on the vent. the detail pane shows the
suggestion, the answer, a model's resolution note with the session that
closed it, and the filing session and workspace; a session shows
by the name someone gave it — a child by its family name, a root by its
title — else by a short id, the same precedence the agents view uses. the
page's glance lists the open vents in the review window, which keeps open vents
ahead of newer finished ones. vents stay out of the chat sidebar, which shows
only the work ledger's active items, the session's scheduled prompts, and its
background jobs.

## storage

vents live in one `paperclips` table in the shared ledger store, created when
the extension is installed. the ledger is global: every query sees every
vent, and the model's `vents()` lists across sessions too, so it can check
for a duplicate before filing. each row records the session id and workspace
(`cwd`) that filed it, shown in the detail pane, and the reply the user
answered it with, added by the `reply` migration, and the resolution note and
resolving session, added by the `resolution` migration. the workspace index from
the cwd-scoped era is dropped by the `scope` migration and fresh installs
never create it. statuses move `open` → `acknowledged` → `resolved` or
`dismissed`; the model's only status change is resolving a vent it fixed,
with a note, and the message of a filed vent is immutable.
