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

- `/fs/list`, `/fs/repo` and `/fs/preview` take `host:/abs` and `host:~`
  too (see browsing).
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

the tui shows a remote workspace as `label:path`, the path folded under
that host's own home once a listing or probe reported it: the chat header
reads `✦ albedo on chernobog:~/proj/albedo`, folds only the path, keeps the
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

`POST /sessions/:id/workspace {"workspace": "/abs/dir"}` answers the session's
info. the session must be idle and the target an existing absolute directory,
or a remote location (stored canonically; an absolute one isn't checked
until a kernel boots there, a `~` one is resolved over ssh first).
`POST /sessions` takes the same forms.
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

all three routes take `path`: absolute, or starting with `~`, which expands
to the daemon's home, or a remote `[user@]host:/abs` or `[user@]host:~/x`
(`~` is that host's home). anything else is a 400; a path that is not an
existing directory is a 404. errors are `{"error": "..."}`. `/health` lists
`workspace_browser` when these routes exist.

a remote path is gathered on its host in one ssh round trip per request
(`priv/python/albedo_gather.py`, after the host's probe, kernel.md): the
directory entries with their stats, which `.jj`/`.git` markers exist, the
very vcs commands `vcs.plan` names (run there with the same 2 s deadline),
and the sizes of tracked files. the daemon reads that snapshot with the
same code it reads its own disk with (`folders.gleam`, `vcs.gleam` over a
`Shell`), so a remote answer is the local answer for the same tree, except
that `path` and `home` are canonical location strings
(`mayer@chernobog:/home/mayer/proj`, `mayer@chernobog:/home/mayer`) so a
client can fold `~`. a repository's `root` stays the plain path on that
host. a host without a ready probe answers 503 `{error, host, state}`
(`needs_auth` with `control_path`, `unreachable`, `unsupported`,
`warming`), so the picker can show it on the row.

### `GET /hosts`

the hosts the picker completes:

```json
{"hosts": [{"host": "mayer@chernobog", "label": "chernobog",
            "source": "recent", "state": "ready"},
           {"host": "devbox", "label": "devbox", "source": "config"}]}
```

- `recent` hosts come from session workspaces, ranked as the picker ranks
  recent folders (per session 4 within the hour, halving past a day, a week
  and a month, summed per host).
- `config` hosts are the `Host` names of the daemon user's
  `~/.ssh/config` and the files it `Include`s, wildcard patterns (`*`, `?`,
  `!`) left out, in file order, after the recent ones and without repeats.
- `host` is the canonical `[user@]host` for `/hosts/:host` and `host:/path`;
  `label` the display form. `state` is the cached probe's when one is
  fresh; listing never probes.

### `GET /fs/list?path=P`

the directories directly inside P, for the picker's list.

```json
{"path": "/Users/dawn/proj", "home": "/Users/dawn", "truncated": false,
 "entries": [{"name": "albedo", "modified": 1790618149, "hidden": false, "vcs": "jj"}]}
```

- `path` is P expanded and normalised (no trailing slash, except `/`).
- only directories, symlinks to directories included; sorted by name,
  case-insensitively. at most 2000; `truncated` says there were more.
- `modified` is the directory's mtime in unix seconds.
- `hidden` is a leading dot. the picker hides these unless the query asks.
- `vcs` is `"jj"` when the entry itself contains `.jj`, else `"git"` when it
  contains `.git` (file or directory), else `null`. a stat, never a process.

### `GET /fs/repo?path=P`

the repository P is in, for list rows: `{"repo": Repo | null}`.

```json
{"kind": "git", "root": "/Users/dawn/proj/tangled", "branch": "master",
 "commit": "4fd0f30", "changed": 3, "touched": 1790610000}
{"kind": "jj", "root": "/Users/dawn/proj/albedo", "change": "nznu",
 "bookmark": {"name": "main", "ahead": 2}, "changed": 1, "touched": 1790618150}
```

- the nearest enclosing root wins, walking up from P. at one level `.jj`
  beats `.git`: a colocated repo's git reports a detached HEAD.
- git: `branch` is null when HEAD is detached; `commit` is the short HEAD id,
  null in an unborn repo. `changed` counts `git status --porcelain=v2` entries,
  untracked included. `touched` is the last commit's time.
- jj: `change` is `@`'s shortest change id (at least 4 characters).
  `bookmark` is the bookmark `@` works on and how many changes `@` is past the
  fork, the newest change in `@`'s history a bookmark contains
  (`heads(::@ & ::bookmarks())`), or null. the name is one at the fork itself,
  local or remote (a colocated repo's `name@git` counts), else the newest
  bookmark that grew from the fork. the nearest bookmark behind `@` would often
  be an old backup of a bookmark that has since moved on. `changed` is the files `@`
  changes. jj runs with `--ignore-working-copy`, so browsing never snapshots
  or writes an operation: `changed` is as fresh as the last jj command.
- every vcs command has a short deadline. a field whose command failed or
  timed out is null; `kind` and `root` are always there.

### `GET /fs/preview?path=P`

everything the preview pane shows for P.

```json
{"path": "/Users/dawn/proj/tangled", "repo": Repo,
 "languages": [{"name": "Go", "color": "#00ADD8", "share": 0.71}],
 "tree": [{"name": "spindle", "dir": true, "changed": 3, "more": 0,
           "children": [{"name": "engine", "dir": true, "changed": 0}]},
          {"name": "flake.nix", "dir": false, "language": "Nix", "changed": 0}],
 "more": 11}
```

- `languages`: the tracked files under P (`git ls-files` / `jj file list`),
  bytes per language, counting only linguist's `programming` and `markup`
  types, as github's language bar does. largest first, at most 4; `share` is
  of all counted bytes. empty outside a repository. `color` is linguist's own
  hex (or null): the tui adapts it to the terminal.
- `tree`: two levels. directories first, then files, each by name; dot
  entries left out. inside a repository only tracked or changed paths show,
  so build output and other ignored files stay out of the way. at most 12 top-level entries (`more` counts the rest);
  a top-level directory lists at most 4 children (its `more` counts the rest)
  and deeper directories list none. `language` names a file's linguist
  language, or null. `changed` counts the changed files at or under an entry.
- language data is github linguist's `languages.yml`, shipped in
  `priv/linguist/` and read once. a file is matched by exact filename, then by
  its longest extension. an extension several languages claim goes to a fixed
  ranking that favours linguist's popular languages and their primary
  extensions (`popular.yml`), so `.md` is Markdown and `.h` is C++.
- `share` is unrounded.

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
  from `/fs/list` with the location; its canonical `path` and `home` fold
  rows to `chernobog:~/proj/albedo`.
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
  picker: `POST /hosts/:host/warm`, then `GET /hosts/:host` every 750 ms
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
