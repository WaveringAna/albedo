# workspaces

a session's workspace is the directory its python kernel, `run` jobs, memory,
skills and AGENTS.md resolve against. `/cd` in the tui moves a session to
another folder; the folder picker browses through the daemon, so it only ever
offers folders the daemon itself can see (and works the same once the daemon
is remote).

## locations

every workspace is a location (`src/albedo/harness/location.gleam`):

- **local**: a plain absolute path, stored exactly as it always was. no
  prefix anywhere, on the wire or on screen. `~` (the daemon's home) parses
  as local too; whether a folder exists is the caller's question.
- **remote**: `[user@]host:/abs/path` (an IPv6 host in brackets). a text is
  remote when it does not start with `/` or `~` and the part before the
  first `:` holds no `/`. user and host start with a letter or digit, so
  neither is ever an ssh option. the path must be absolute and is
  normalised (`//`, `.`, `..`, trailing slash), so one remote directory has
  one key. a stored remote path is always absolute: `host:~` and
  `host:~/x` given to create or move a session are resolved against that
  host's home (one probe over ssh, bounded, kernel.md) and stored absolute;
  an unreachable host refuses with ssh's words.

session info carries the parsed location beside the `workspace` string:

```json
{"workspace": "mayer@chernobog:/home/mayer/proj/albedo",
 "location": {"host": "chernobog", "user": "mayer",
              "path": "/home/mayer/proj/albedo", "label": "chernobog"}}
{"workspace": "/Users/dawn/proj", "location":
 {"host": null, "user": null, "path": "/Users/dawn/proj", "label": null}}
```

`label` is how clients show the host: the alias, with `user@` dropped when
it is the user `ssh -G <host>` reports (local config only, no network),
cached per host for the daemon's life. without ssh the user stays.

a remote session's python kernel and `run` jobs run on its host
(kernel.md, "remote kernels"). what is only a key works as it is: the work
ledger and paperclips scope, workspace links, recent folders, session search by cwd, family
moves. what the daemon itself reads from a workspace goes through the
location, and never looks for a remote path on its own disk:

- `/workspaces` accepts remote `location` values such as `host:/abs` and
  `host:~` too (see browsing).
- AGENTS.md, SYSTEM.md and the other instruction files, and project skills,
  are read from a daemon-side mirror of the remote workspace's project
  files (`$ALBEDO_HOME/mirror/<digest>/`: root `*.md`, `.agents/*.md`,
  `.albedo/*.md`, and the `.agents/skills` and `.albedo/skills` trees, at
  most 512 files and 8 MiB, each read up to one byte past the 1 MiB
  instruction limit). one gather over ssh fills it, at most every 5 s, and
  the local readers read it as the workspace, so the same rules apply. a
  skill's `location` is its mirror path. while the host is out of reach
  only the home directories count, and the instructions warn and the
  skills catalog diagnoses `project … skipped: can't reach chernobog: …`.
- memory is a daemon-side file keyed by the workspace string, so a remote
  workspace gets its own. the kernel's `memory` object reaches it through the
  `memory` host route wherever the kernel runs (`memory.read`, `.save`,
  `.append`, `.journal`, `.documents`; synchronous over the kernel's
  `host_now`), so a remote session's notes land in the daemon's
  `$ALBEDO_HOME/memories`, never the host's.

## linked workspaces

a workspace can be linked with others that hold the same project, such as one
repository checked out here and on chernobog (`src/albedo/harness/links.gleam`,
the `links` extension). links are peers: every member keeps writing its own
memory and work items, and reads cover the whole group.

- storage: `workspace_links(workspace, grp)` in the daemon's sqlite. linking
  two workspaces merges their groups; unlinking one takes only that row out,
  and a group left with one member is dropped. nothing else changes, so
  unlinking (or linking again) loses and repeats nothing.
- memory: the snapshot a session opens with shows its own memory, then each
  linked member's under `## linked workspace <location>`, within the same
  8000-character budget. `memory.read()` is this workspace's file only;
  `grep` and `search` cover the group, a linked file named
  `[<location>] memory.md`. `save`, `append` and `journal` write here.
- work ledger: `list`, `get`, `update` and `delete` reach every member's
  items, an update or delete stays in the item's own workspace, and `create`
  files under this one. each item carries `workspace`; the `/work` page says
  where an item from another member was filed.
- vents are one ledger for every workspace already, so links change nothing
  there.
- the model is told it is linked (the `links` context, naming each member,
  and marking one whose folder is gone).
- linking or unlinking queues a note in every open session of every
  workspace it touches, worded for that side ("linked this workspace with
  X" / "unlinked X" / "unlinked this workspace from Y, Z"). a link note
  carries the newly linked members' memory as a new session's snapshot holds
  it (`albedo_memory:linked`), so a session that opened before the link
  reads the same text without rebuilding its prompt and losing its prompt
  cache; its snapshot catches up at the next rebuild. open means the session
  has a live actor (and so a cached composition); any other session composes
  its snapshot afresh when it opens. live reads (`grep`, `search`, the work
  ledger) follow the group on every call anyway.
- a member's folder is checked where it is: a local one on the daemon's
  disk, a remote one with one `exists` gather on its host over the shared
  ControlMaster (`folders.exists`). a host that does not answer is never
  read as a gone folder. every member is checked at once, so slow hosts
  wait side by side. the `/link` page waits up to 5 s for a host and
  then says why (`connecting`, `sign in`, `unreachable`, with ssh's words);
  the session-start context takes only a recent probe, starting one in the
  background, so opening a session never waits on a host.
- `/link` (user only for changes) lists the members: this one `here`, a
  member whose folder no longer exists `gone`, a remote one whose host can't
  say as above. `add <workspace>` takes what a session can be created in (an
  existing local directory, or `host:/abs` / `host:~/x`) and refuses this
  workspace and one already linked; `remove <workspace>` takes a listed one,
  this one included (leaving the group). a gone member stays, read as before,
  until it is removed.

a worktree or jj workspace of the same repository is not linked by itself
yet; that and suggesting links from shared history are later work.

the tui shows a remote workspace as `label:path`, the path relative to that
host's own home once a listing or probe reported it, as scp reads it (the
home itself is `label:~`, a path outside it stays absolute): the chat header
reads `✦ albedo on chernobog:proj/albedo`, folds only the path, keeps the
host in every layout that shows a place, and colors the host with a stable
hue derived from its label, lifted to the theme's contrast. the host goes
faint while the session's kernel boots or reattaches (the status line says
`connecting to chernobog…` with an animated face, the same one the picker
shows beside a host still warming, picked by the host's label, or `copying
the kernel to chernobog…` while albedo is staged there) and takes the error
color once it is lost (the port owner gave up and forgot the kernel, so the
status line says the next turn starts a fresh one), from the session
status's `kernel.link` (kernel.md). recent folders and the
sessions view lead remote entries with their host.

## moving a session

`PATCH /sessions/{session_id}?view=configuration` changes `workspace` under
the observed `If-Match` validator. Its result distinguishes committed desired
state from application outcomes. the session must be idle and the target an existing absolute directory,
or a remote location (stored canonically; an absolute one isn't checked
until a kernel boots there, a `~` one is resolved over ssh first).
`PUT /sessions/{session_id}` creates a new session with the same location forms.
the kernel is dropped (python variables start fresh), the transcript stays,
and a note records the move.

every descendant of the session (children, their children; open or closed)
whose workspace was the same folder follows it. an idle descendant moves at
once; a running one moves when its current turn ends. descendants that were
working somewhere else keep their own folder. if the session itself cannot
move, nobody moves.

after a move the tui offers linking the folder the session left, as a notice
to paste: `/link add <folder as stored>` (absolute, `user@` kept, so the link
lands on the key that folder's memory and work items use). a later move
replaces it, and a move away from a folder that went missing offers nothing.
it does not check whether the two are already linked; `/link add` refuses
that.

## browsing

`GET /workspaces` lists recent workspaces. With `location`, it lists child
folders and canonical parent, home, and host state. `include=preview` adds
repository facts, language shares, and a bounded two-level file tree.
[The HTTP contract](../docs/http-api-design.md#models-workspaces-hosts-and-provider-login)
and [OpenAPI](../docs/openapi.yaml) define the requests and responses.

Locations are absolute paths, daemon-relative `~` paths, or remote
`[user@]host:/abs` and `[user@]host:~/x` paths. Remote browsing gathers one
snapshot over SSH after the host probe. Local and remote snapshots use the
same folder and VCS readers. The nearest enclosing repository wins; a
colocated `.jj` takes precedence over `.git`. VCS commands have short deadlines,
and unavailable optional facts do not discard the folder listing.

Language shares use tracked file sizes and the bundled GitHub Linguist data.
The tree shows tracked or changed paths, excluding ignored build output.
Browsing jj uses `--ignore-working-copy` and does not create a snapshot.

`GET /hosts` lists recent and SSH-config targets with cached probe state.
`POST /hosts/{host}/probe` starts or joins a probe. Clients poll `GET /hosts?target=<host>`
until it completes, including targets absent from SSH config and session history.
SSH sign-in remains an explicit operator action.

## the picker

`/cd` opens it full screen; `/cd <path>` moves at once. an empty query lists
recent folders (the workspaces of your sessions, local and remote, ranked by
how often and how recently they were used). typing a path lists that
folder's directories, filtered by the last segment. tab enters the
highlighted folder, shift+tab goes up, enter moves there, esc goes back. the
same picker replaces the plain text box shown when a session's workspace has
gone missing.

the query takes scp syntax for another host, so a host is picked like a
folder (`cli/internal/tui/folder_picker.go`, `parseQuery`):

- `chernobog:` lists that host's home, `chernobog:proj/` and
  `chernobog:~/proj/` browse under it, `chernobog:/srv/` from its root.
  everything after the last slash filters, as locally. the listing comes
  from `/workspaces` with `location`; its canonical `path` and `home` fold
  rows to `chernobog:proj/albedo`.
- hosts complete from `GET /hosts` (recent first, then ssh config), with the
  hosts of the sessions already listed as a fallback. a bare word still
  filters the recent folders exactly as before and only adds the hosts whose
  name it starts, after the folders, so `cher` offers `chernobog:` without
  turning a local filter fuzzy. text with an `@` and no `:` can only be
  `user@host`: it lists hosts alone, fuzzy on the host part, and the typed
  user goes with the completion. tab or enter on a host completes to
  `host:`.
- highlighting a remote row (a recent remote folder, a host, a folder in a
  remote listing), or typing a remote listing, warms its host once per
  picker: `POST /hosts/{host}/probe`, then `GET /hosts?target={host}` every 750 ms
  until the probe settles. the row shows it quietly: faint while warming,
  plain once ready, the probe's detail in the error style when unreachable
  or unsupported, `sign in · ctrl+l` when it needs a person. ctrl+l runs the
  same `ssh -M -fN` handoff a refused turn offers (kernel.md, "signing
  in"), with the `control_path` the probe answered, then warms the host
  again. repositories and the preview of a remote row wait for ready; until
  then the pane shows the host's state, and when ready its os, arch and ~.
- enter never picks a dead host: on an unreachable, unsupported or
  needs-auth host it stays and says why in the footer.

in the sessions view, ctrl+f (or `~` or `/` typed into an empty search) opens
the same picker to browse sessions by folder: enter starts a new session in
the highlighted folder instead of moving one. in either mode → steps into the
highlighted folder's sessions, where enter opens one and ← goes back.

the preview keeps its sessions on screen: the tree fits around a third of
the pane kept for them, showing fewer children per directory, then only
the top level, then fewer top entries, and the sessions fill whatever the
tree leaves.
