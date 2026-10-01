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
  one key. a remote `~` is refused: the remote home is only known once
  albedo connects there.

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

nothing runs at a remote location yet. what is only a key works as it is:
the work ledger and paperclips scope, recent folders, session search by
cwd, family moves. what needs the remote filesystem refuses or skips by
name, and never looks for the path on the daemon's own disk:

- a turn in a remote session answers 409 `kernels on chernobog aren't
  available yet` (the kernel refuses to boot there too).
- `/fs/list`, `/fs/repo` and `/fs/preview` answer 400 `folders on chernobog
  aren't available yet`.
- AGENTS.md, SYSTEM.md and the other instruction files, and skills, are
  read from the home directories only; the instructions extension warns
  `project instruction files on chernobog aren't available yet` and the
  skills catalog lists `project skills on chernobog aren't available yet`
  among its diagnostics.
- memory is a daemon-side file keyed by the workspace string, so a remote
  workspace gets its own.

the tui shows a remote workspace as `label:/path`: the chat header reads
`✦ albedo on chernobog:/home/mayer/proj/albedo`, folds only the path, keeps
the host in every layout that shows a place, and colors the host with a
stable hue derived from its label, lifted to the theme's contrast. recent
folders and the sessions view lead remote entries with their host.

## moving a session

`POST /sessions/:id/workspace {"workspace": "/abs/dir"}` answers the session's
info. the session must be idle and the target an existing absolute directory,
or a remote location (stored canonically; it can't be checked before albedo
connects to the host). `POST /sessions` takes the same forms.
the kernel is dropped (python variables start fresh), the transcript stays,
and a note records the move.

every descendant of the session (children, their children; open or closed)
whose workspace was the same folder follows it. an idle descendant moves at
once; a running one moves when its current turn ends. descendants that were
working somewhere else keep their own folder. if the session itself cannot
move, nobody moves.

## browsing

all three routes take `path`: absolute, or starting with `~`, which expands
to the daemon's home. anything else is a 400, a remote location included; a path that is not an existing
directory is a 404. errors are `{"error": "..."}`. `/health` lists
`workspace_browser` when these routes exist.

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
recent folders (the workspaces of your sessions, ranked by how often and how
recently they were used). typing a path lists that folder's directories,
filtered by the last segment. tab enters the highlighted folder, shift+tab goes
up, enter moves there, esc goes back. the same picker replaces the plain text
box shown when a session's workspace has gone missing.

in the sessions view, ctrl+f (or `~` or `/` typed into an empty search) opens
the same picker to browse sessions by folder: enter starts a new session in
the highlighted folder instead of moving one. in either mode → steps into the
highlighted folder's sessions, where enter opens one and ← goes back.

the preview keeps its sessions on screen: the tree fits around a third of
the pane kept for them, showing fewer children per directory, then only
the top level, then fewer top entries, and the sessions fill whatever the
tree leaves.
