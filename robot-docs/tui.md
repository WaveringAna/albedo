# tui

the terminal client's screens, how they share one look and one set of keys, and how to see them. the code is `cli/internal/tui`. the daemon owns the data; this page is only about rendering and keys.

## what the screens share

every list screen is built from the same four parts. a new list screen composes them and writes no layout of its own.

| part | file | owns |
| --- | --- | --- |
| `listFrame` | `frame.go` | the whole layout: indented title rule, filter line, list, detail pane, footer, one clip to the terminal height |
| `listView` | `list_view.go` | the always-live filter, the cursor, groups and sections, row drawing, the pane's contents (`listEntry`, `paneTitle`, `factRows`, `paneNote`). a row's `group` puts its section under a bold heading (`/config`'s categories); a filter ranks sections within their group and groups by their best section, so a group never splits |
| `confirm` | `confirm.go` | the one yes/no question |
| `matchFields`, `searchWords` | `model_search.go` | the one fuzzy matcher every filter uses |

`pageStatus` (`page.go`) is the small state every screen embeds beside those: width and height, the load or save in flight, the last error and notice, and the generation that makes a stale reply harmless (`settle`). every command carries the generation it started under.

on the shared look: `/model`, `/sessions`, `/folders`, `/extensions`, `/skills`, `/instructions`, `/mcp`, `/webhooks`, `/discord`, `/config` (`/settings`), `/tree`, `/quota`, `/context`, `/login`, and the daemon-driven pages (`/work`, `/paperclips`, `/schedule`, `/links`, run jobs, web-search order).

not on it, on purpose: the chat (a transcript is not a list) and the agents canvas (a graph). the agents delete question still uses `confirm`.

## layout

- the title is `brand("albedo") + " " + Muted("/command")`. the frame draws the rule and the right-hand summary.
- at width >= 96 and height >= 14 the detail pane sits beside the list. below that it stacks under the list when the body has at least 12 rows (the pane gets two fifths of the body), and is dropped otherwise. a screen supplies `pane` and gets all three behaviours; it never decides.
- the frame clips to the terminal once. screens do not truncate, pad or count rows, and there are no `Height-N` constants.
- the filter line is hidden only while a form is open over the list.
- `footerLine(width, hints, status, urgent)` builds the footer: keys on the left, a status on the right. an urgent status (error, notice, work in flight) takes its own row above the keys when it does not fit beside them.
- list hints most important first and `esc` last. `fitHints` sheds the least important from the end, keeps `esc`, and drops every label before it drops a key.
- an empty list says why in `listView.Empty`. errors and notices go in the footer status, never into rows.
- a pane shows what used to need enter to see (an mcp server's settings, a webhook's url and state, a skill's source). nothing important lives only below the list.

## keys

the filter is always live and focused, so a bare letter is typed into it. no list screen has a bare-letter action, and none toggles on space. `esc` is always back, even with text typed; inside a confirm it cancels the confirm, inside a form it cancels the form.

these mean the same thing on every screen that has them:

| key | does |
| --- | --- |
| up/down, ctrl+p/ctrl+n, pgup/pgdn | move (owned by `listView`) |
| enter | the row's main action |
| shift+enter, alt+enter | the same action for this session only, where a screen has a session scope |
| ctrl+x | drop this session's own choice and follow global |
| ctrl+d | delete, remove or unlink, always after a confirm |
| ctrl+e | edit |
| ctrl+o | add, create, link |
| ctrl+r | refresh, or retry a failed load |

other chords belong to one screen and say so in their hint: `ctrl+t` (enable an extension on `/skills`, reply or toggle on pages, agent access on `/webhooks`), `ctrl+g` (enable an mcp server, new webhook secret, done or acknowledge on pages), `ctrl+l` (copy a webhook url, sign in on `/folders`), `ctrl+w` (webhooks or discord from `/extensions`), `ctrl+a` (actions menu on pages, archive on `/sessions`), `ctrl+s` (save a form, pin a session).

known exceptions to the table: on `/sessions` `ctrl+r` renames (on `/folders` it retries), and on the agents canvas `ctrl+x` deletes. on `/discord` a bot's channels cycle their delivery on space (Discord channel names have no spaces, so the filter never needs one) and `ctrl+t` toggles mentions-only; `tab` switches between its channels and DMs. pages use `ctrl+x` for dismiss or stop. on `/config` `ctrl+x` drops a setting's saved value so its default applies, and `enter` and `ctrl+e` both edit the highlighted field, which is the one save the screen has. a terminal without the kitty keyboard protocol sends plain enter for shift+enter, so the confirm on `/extensions`, `/skills` and `/mcp` names its scope ("globally?" or "for this session only?") and a mixup is visible before enter.

## confirms

`confirm` is the only way a screen asks. enter does it, esc or ctrl+c cancels, every other key is ignored, so a stray press while you read the question changes nothing. never "any other key cancels" and never `y`. a confirm is for destructive or far-reaching actions (delete, a new secret, enabling something that reloads the session); toggles that are cheap to undo act directly. a failed attempt keeps the question open with enter as retry.

## adding a screen

1. embed `pageStatus`, `listView` and `confirm`; rebuild rows with `setRows`.
2. ask the confirm first with `confirm.ask(what, target, verb, prompt)`, act on `confirm.key`.
3. draw with `listView.frame(title, right, footer).view(w, h)`. build the footer with `footerLine`, or `confirm.footer` while asking.
4. call `listView.update` for movement and typing and compute its command before returning the model (`cmd := m.listView.update(msg); return m, cmd`). go does not promise the order in which `return m, m.listView.update(msg)` reads `m` and runs the call, and the returned model can miss the filter change.
5. register the screen's states for the gallery (below).

## seeing the screens

`ALBEDO_SHOT_DIR` makes tests write what a view draws. nothing is written without it, so the gate never creates files. `shotTerminal(t)` gives the styles a real terminal with its own palette would get; without it a test falls back to reverse video and the selection looks wrong.

```
ALBEDO_SHOT_DIR=/tmp/shots go -C cli test ./internal/tui -run TestShotGallery -count=1
python3 test/manual/tui_shot.py /tmp/shots
```

each screen calls `registerShots("<screen>", states...)` from its `shot_<screen>_test.go`. `TestShotGallery` draws every registered state at 120x30 (wide) and 70x20 (narrow). `tui_shot.py` turns each `.ans` into a png (needs `rsvg-convert` and ImageMagick) and builds contact sheets, `sheet-<screen>-<n>.png`, six states per sheet so each stays under the 2000px edge a model can read. run one screen with `-run TestShotGallery/<screen>`.

cover every state a person would want to look at: the list, a filter typed, no match, each confirm, loading, empty, load failed, a notice, a form open. look at the sheets after a layout change; text dumps hid a patchwork selection and a collapsed footer that the pictures showed at once.

## markdown

replies render through glamour, from our fork `tangled.org/okami.mom/glamour` (`replace` in `cli/go.mod`; v2.0.1 plus hooks). `glamour.WithExtensions` adds goldmark parsers and `glamour.WithElement(kind, fn)` renders a node kind, new or built in; `ansi.RenderContext.Width()` is the room left inside the current block. the fork also renders list items as blocks: every row after the marker's hangs under the item's text, so wrapped lines, paragraphs, code and display math stay inside the item (`style.List.LevelIndent` is 0 because the hang already indents nested lists). upstream glamour has neither hook, and prints a warning to stdout for a node kind it does not know, which corrupts the screen.

to add a construct, write its goldmark parser and node, then its element, in one file beside `markdown.go`, and pass both in `markdownRenderer`. `math.go` is the example: `$…$` and `\(…\)` inline, `$$…$$` and `\[…\]` on their own lines as display math, laid out in unicode by `termtex`. a lone `$` opens only before a non-space and after no word character, and closes only before no word character, so `$5` and `$HOME/$USER` stay text. display math that has not closed yet, or that termtex cannot read, shows as its source. `fenceAfter` treats open display math like a code fence, so streaming never splits it into blocks. use `ansi.BaseElement{Verbatim: true}` for laid-out text; without it glamour removes markdown escapes from the token.

markdown's colors are ink accents (`markdownAccents` in `ink.go`), palette hues made legible on the background: headings violet, strong text yellow toward red, inline code green, links blue, math cyan. headings and strong text sit at a higher contrast than the others. without reported colors each falls back to its palette slot.

a reply still arriving renders block by block (`growingMarkdown` in `markdown.go`, rows in `liveRender` in `chat_history.go`): a top-level block is rendered once against the block before it (`markdownPiece`), framed, wrapped and hung on the rail once, and kept; a draw renders, wraps and measures only the block still growing, so a 30 KB reply costs a draw what its newest block costs rather than the whole reply. the scan that finds block boundaries (`blockScan`) reads only the text that arrived since the last draw, and stops at the last newline while a line is still coming, since half a line cannot be told from a whole one.

a piece ends at a *position* in the rendering, not at the end of a row: the spaces that fill out a row arrive with the piece after it, so a row can be split across pieces. `liveRender` therefore frames only the lines a piece completed and carries the line still growing (`line`) into the next piece, which is why the rows a draw shows are the rows of the whole rendering and not of a piecewise one. a thought is greyed through the same `faintRows` the settled path uses, `LiveHead`/`LiveBody` mirror `RenderAfter` row for row. text that cannot be split (a link definition, a raw `<pre>`) is rendered whole on every draw, which is what the live rows look like before the first block boundary. `live_rows_test.go` streams a reply with fences, lists, a table and display math and requires the live rows to equal a whole render's at every delta.

code block themes are built once per palette (`codeStyle`, kept in a `sync.Map` keyed by the ink) and handed to chroma's formatter directly; `codeTheme` only names it in chroma's registry, because glamour resolves a code block's theme by name. chroma's own `styles` package init (1.9 MB) cannot be dropped: `charm.land/glamour/v2/ansi` imports it and `quick`, so it runs for every client (`GODEBUG=inittrace=1` shows it), and the import is not what a draw pays for.

## the frame

the chat's frame is one string: header, notices, the transcript pane, the status line, the chips, the composer, the command menu and the footer, joined and padded. three pieces cost more than building all the rest, so each is built once per change and reused (`frameCache` in `chat_view.go`):

- the transcript body: the viewport's rows padded to the pane's width with the glance column appended beside them (`joinBody`), cached on the pane's rows, its width and the column.
- the glance column: the sidebar's rows rendered and padded to its width, cached on the glances the daemon sent (compared by the fields a row draws from: the title, and each row's id, text and tone), the aged background jobs, and the width and height. a status poll replaces the glances wholesale, so an equal list reuses the column.
- the input block: `textarea.View()` splits and re-wraps the draft and pads its whole viewport on every call. cached on the value, the caret, the size, the placeholder and the focus — and any message that reaches the textarea forgets it, because a selection or the virtual cursor moves without changing those.

everything else (header, status line, chips, separators, footer) is rebuilt every frame: that is a few microseconds, and building it means it cannot be stale. the padded rows are kept too, so a frame nothing changed in returns the very string it returned last time, and Bubble Tea skips parsing and painting it (`viewEquals` in its renderer). every input to a cache is compared by value rather than hashed: a stale screen is worse than the comparison.

`frame_cache_test.go` replays a scripted session through the cached and from-scratch paths and requires the same bytes at every step.

## terminal output

bubble tea is our patched copy in `cli/third_party/bubbletea` (`replace` in `cli/go.mod`; v2.0.10 plus `cli/third_party/bubbletea.patch`). upstream flushes from a ticker at the program's fps for as long as it runs, so an idle client still woke 60 times a second to compare an unchanged frame: about 80% of a resting client's cpu. the copy's frame writer sleeps until `render()` or `execute()` asks for a frame, then paints at most once per frame interval, so the fps cap still coalesces a stream and a change paints right away instead of on the next tick. anything that writes to the terminal outside `View` must go through `execute` so it gets flushed. to bump bubble tea, copy the new release over the directory and reapply the patch; `TestBubbleteaIsThePatchedCopy` fails if the `replace` is dropped.

transcript rows carry private `albedo:` APC marks for copy, wrap joining and click targets. they stay in the chat's internal rows (`frameLines`), but no frame carries them: `ChatModel.View` strips them (`stripPrivateMarks`) as it joins the string Bubble Tea sees, and `AppModel.View` scans the other screens, which carry none. ultraviolet preserves APC payloads; terminal.app prints unknown ones, which corrupts the layout. remove only our private marks, not styling, hyperlinks or graphics sequences. the real-daemon TUI driver's view assertion checks the raw content before `ansi.Strip` can hide a leak.

the view asks the terminal to report focus (`tea.View.ReportFocus`), so a client can stop animating while its terminal is in the background. a terminal or multiplexer that never reports focus never sends those messages and behaves as it always did; tmux forwards them only with `focus-events on`.

ctrl- or cmd-click on a transcript row opens the file it names (`editor.go`, `openFileAt`); a plain click keeps its row action. the token under the click wins, else the row's only existing file; a numbered diff row opens its file at that line, read after the rail (`rowBody`). only regular files that exist under the workspace (or absolute) open. inside zed's or a vs code family terminal (`TERM_PROGRAM`, `VSCODE_PID`, `ZED_TERM`) the file opens through that editor's cli in the background; otherwise through `$EDITOR`, run on the terminal with `tea.Exec` unless it is a gui editor. `cli/test/e2e/tui_open_file_test.go` clicks real rendered rows.

## history navigation

`/tree` rewinds the current session in place to before a selected user message (`GET /sessions/{id}/history?view=checkpoints` lists them, `POST /sessions/{id}/rewind` cuts). In the picker `enter` rewinds, `ctrl+s` rewinds and asks for a summary of what it removes, and `ctrl+g` forks a new session instead (plain letters stay with the type-to-filter field); each asks first, with the usual enter-or-esc question. `/fork` opens the same picker with only the fork, as `/tree` used to. A rewind keeps the session's id: the app rebuilds its chat model for that id so the daemon's reset hydrates it fresh, puts the removed message back in the composer unless a draft is there (a draft wins), and adds a note naming the archive the earlier conversation went to. See [rewind](sessions.md#rewind).

## chat liveliness

the chat wakes up for a handful of reasons, and each one is priced:

| wakeup | when | cost |
| --- | --- | --- |
| face tick (`faceInterval`, 500ms) | only while the person waits on the session: a message on its way, a turn running, a tool working, a host being reached (`ChatModel.animating`) | one `View()` and one frame flush |
| status read | one safety read a minute while the stream is healthy (`statusPollCmd`) | one `GET /sessions/{id}?view=status` and a frame; the daemon answers from the session's memory and its kernel, observing the composition only when no stream has published the sidebars ([sessions](sessions.md#live-status-without-a-poll)) |
| live reply draw | at most once per `liveFrame` (120ms) while a reply grows, or 4x the last render | rendering the block still growing, and framing what it adds |
| agents canvas frame | 120ms while a node moves (`agentsFrame`) | one canvas frame |

what the client shows about the kernel and the sidebar is pushed, not polled: the stream's reset carries everything on attach, `kernel` arrives when the job facts change, and `glances` when the sidebar's values do. the minute-long read is there for a daemon too old to push them (the events are additive, so an old daemon simply never sends them); a live event bumps `statusRevision`, which drops any reply already in flight.

background work is not a wait. an idle session whose `run()` jobs are still going keeps the status line's static marker (`N background jobs running · <command>`) and the sidebar's job glance, both kept current by the pushed facts, and draws no face: an hour-long job costs the client nothing per second. the face only moves for what the person is waiting on, which is also why an idle session with a job shows the composer's hint — it is a session you can type into.

a terminal that reports focus (`ReportFocus`, bubbletea's `FocusMsg`/`BlurMsg`) also says when nobody is looking: losing focus ends the face animation, and focus coming back reads status at once and starts the face again. a terminal that never reports focus never blurs, and behaves as it always did.

## tests

unit tests here catch what the daemon e2e cannot drive: key routing, stale replies, in-flight save rendering, footer fitting. the screen-level scenarios in `cli/test/e2e` drive the real daemon through the same keys. when a screen changes keys, update both and the gallery state that shows the footer.
