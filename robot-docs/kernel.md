# the detached kernel

a session's python kernel (`priv/python/albedo_kernel.py`, which runs
`albedo_cells.py` as `__main__` so its bytecode comes from the cache) is its own process,
detached from the daemon: it outlives a dropped connection and a daemon
restart, keeping its namespace and its background jobs. the daemon connects
to it directly, or through a bridge when it runs on another host, and every message between the two travels through a small
session layer that neither loses nor repeats a message across a reconnect.

## tool bindings

Cells also see the common standard-library modules (`asyncio base64 collections datetime functools hashlib itertools json math os re shutil sys textwrap time`, and `Path`) without importing them; these live in the same session-private builtins, so they are not saved as user variables. `import albedo` and `from albedo import files` answer the injected bindings (`albedo_cells.Bindings`).

A cell may not block the kernel with `time.sleep` of a second or more: `albedo_shell` refuses it through the same audit hook that refuses raw subprocess calls, and says to start the work with `run()` and do other useful work while it runs, and when nothing else is left to give the user a status report first, then wait with `await asyncio.sleep(n)`. Job timeouts are seconds, at most a day (`albedo_api.check_timeout`): a job outlives the cell that started it, so it is not held to the cell's hour.

The kernel keeps injected helpers in cell globals and in a session-private copy
of Python's builtins. An assignment such as `files = [...]` shadows the helper;
`del files` reveals the original binding again, including inside functions and
later cells. The process-wide `builtins` module is unchanged. Plugin instances
are owned by this kernel's API, not module-level singletons. This fallback is
built once after plugins load and is not serialized with user state.

## background job observations

`GET /sessions/{id}` exposes `kernel.live_job_count` and `kernel.running_jobs`
without starting a kernel. Unknown observations are null. The list contains up
to 100 live jobs ordered by ID, with `id`, nullable `pid`, `command` (up to
4096 scalars), and `started_at`: wall-clock milliseconds when the port owner
recorded the job's group, zero when unknown (a restored link older than the
field). The count can exceed the list when remote jobs have no summaries.
The TUI uses these observations for its idle-job status, animation, and
sidebar, and calls a job background only once it has run three seconds
(`jobGrace`), so work a cell starts and awaits never flashes through the
chrome; `/jobs` lists every live job regardless of age. The chat reads these
every 750 ms while anything is live (a turn, a job, a booting or reattaching
kernel) and every 5 s otherwise; a live stream event wakes a resting poll.
The Erlang port owner truncates commands through `text_scalars.take`, which
scans only the retained prefix and copies it. Do not convert the entire command
to a codepoint list to take a bounded preview; see [runtime](runtime.md#unicode-scalar-limits).

`/jobs` reads `GET /extensions/run/sessions/{id}/jobs`, whose page declares the
stop action. `POST /extensions/run/sessions/{id}/jobs/{job_id}/stop` supervises
that job's recorded process group and reports failure if its stop is unconfirmed.
A missing job returns 404. After response loss, read the collection before
confirming another attempt; stopping is never automatically retried. Job rows
carry no resource; the stop action binds the row id.

A job that finishes with its result unread wakes the session. The model reads
the full notice with the job's handle; the transcript keeps the wake's one-line
display (`job finished (exit_code=0, ran 1.2s): …`) as a note from `job`.

## retained output

Every cell and job owns one output channel (`albedo_capture.Capture`), kept
for the 16 newest cells and 64 newest jobs plus `native`. A channel holds the
first 1 MiB as written and, once more than that has arrived, the last 64 KiB
in a separate tail buffer that exists only from then on; `seen` counts
everything. Job and remote output enter as bytes (`write_bytes`), never
decoded and re-encoded, so a UTF-8 character split across two pipe reads
survives and a late `job.pipe()` replays the exact bytes while `seen` still
fits in the retained start. Text readers (`output.read`, `tail()`, previews)
decode a window on demand. A single print longer than what could be retained
is not encoded whole when it is ASCII: the buffers see both ends and the
middle only counts.

Finished results are kept by cell id (the newest 16) for execute replays.
Their base64 image text is capped at 8 MiB across all of them, newest first;
an older result past the budget replays without its images and says so in
its output.

## background cells

The kernel returns a python tool result with `status=backgrounded` after 60
seconds (`ALBEDO_CELL_BACKGROUND_SECONDS` overrides the threshold, in seconds).
The result includes output so far, the cell id, and instructions to do useful
work or report status and end the turn, without polling or sleeping. This is not
a final outcome: the journal stays `started` until `cells.finish` records it.
`cells.info/read/trace` remain available; traces appear when execution finishes.
The original `timeout_ms` is carried to the kernel and still interrupts the cell
at its deadline, even after the daemon's original execute wait has ended.

New cells can run while a detached cell awaits. They share the namespace, so
avoid modifying variables the detached cell uses. Python output, images, and
activity traces use the task's context; native fd output goes to `native` when
multiple cells run, since it cannot be attributed safely. A synchronous cell
can return its tool result early, but other cells must wait until it yields or
finishes. Background and deadline timers run outside the asyncio loop so a
synchronous cell cannot prevent its deadline from firing.

At most 16 cells run concurrently. Running captures are protected from eviction; completed output rolls out
under the existing 16-capture limit. `await cells.cancel(id)` requests cancellation and
suppresses that cell's wake. Explicit kernel reset/replacement ends its cells;
a daemon restart merely reattaches. Internal `cells` count frames, replayed in
the hello, keep idle reaping and automatic stale-kernel replacement from ending
a running cell without pretending the cells are process jobs in the public API.

Completion is committed before `cells.completed` sends a wake. The transcript
gets a one-line `cell finished (status=ok, ran 90.0s): <first code line>` from
`cell`, while the model gets the full notice with the cell id separately. Unread completions share a wake and retry
every two seconds while the session is busy; there is no model polling. The final expression is appended to retained output under `[result]`, so
`output.read(id)` can read it after a background completion. Reading finished
output, source, status, or trace retires a pending wake.
Reading partial output while the cell still runs does not retire its eventual
completion. A read racing with the completion journal also retires the wake.

## processes

- **kernel**: started in its own session and process group, stdio not tied to
  anyone. it listens on `kernel.sock` in its run directory,
  `$ALBEDO_HOME/run/<kernel id>/` (0700; the socket is bound relative to the
  directory so a long temp home stays under the ~104-byte `sun_path` limit).
  `kernel.log` there catches what it writes before its own output capture
  starts.
- **relay** (in `albedo_python.erl`): how the port owner reaches a local
  kernel. an erlang process owns a `gen_tcp` connection to `kernel.sock`
  (`{packet, 4}`) and passes frames to the port owner as a bridge port would,
  so no python process stays beside a local kernel. a fresh boot first runs
  `albedo_bridge.py launch <run_dir> <modules-json>` (token as its one stdin
  line), which starts the kernel and exits once the socket answers. the relay
  announces nothing, so the port owner hashes the bundle itself, the same way
  `albedo_bundle.digest()` does. a refused or missing socket reads as exit 3.
  a run directory whose socket path does not fit `sun_path` (104 bytes) keeps
  the bridge.
- **bridge** (`priv/python/albedo_bridge.py`): what the daemon's erlang port
  runs for a remote kernel (the same argv over ssh, see remote kernels below)
  or a run directory too deep for the relay, with the same `{packet, 4}` stdio
  framing the kernel used to have. `start <run_dir> <modules-json>` starts the
  kernel beside it (the token goes over the kernel's stdin, never argv) and
  waits for its socket; `attach <run_dir>` connects to a running one. it
  announces its own bundle hash (`{"bridge": {"bundle"}}`), then copies bytes
  both ways until either side closes. exit status 3 means no kernel is there.
  killing it never touches the kernel.
- **port owner** (`albedo_python.erl`): one erlang process per kernel, as
  before. it owns the job groups the kernel reports and the
  `albedo_signal.py` termination ladder, aimed at the pid/pgid/leader the
  kernel declares in its hello.

a kernel run with plain `albedo_kernel.py <modules>` (no `--run`) keeps the
old raw stdio protocol and dies with its pipe: the remote plugin's targets use
that.

## handshake

the daemon writes `{"attach": {"kernel", "token", "ack", "grace"}}` first. the
kernel checks the token (kept in the daemon's sqlite), bumps its epoch, cuts
off any older connection (newest attach wins), and answers
`{"hello": {protocol, bundle, epoch, ack, pid, pgid, leader, ready, jobs,
external, dropped}}`, or `{"refused": reason}`. `protocol` (1) and the
hello reports the running `cells` count. `bundle` is
`albedo_bundle.digest()`, the same content hash the remote plugin stages
under; a hello whose bundle or protocol differs from the bridge's (or, for a
local kernel, the port owner's own hash) makes the
kernel stale (see version skew). `jobs` (live `job_start` frames) and `external`
let a fresh port owner take over job ownership and live-job observations.

## session layer

after the handshake every frame is `{"seq": n, "ack": m, "frame": {...}}`, or
a bare `{"ack": m}`. `ack` is cumulative: everything up to it arrived.

- **kernel side** (`priv/python/albedo_link.py`): an in-memory outbox of
  unacknowledged frames, resent after each hello. `mirror` (per handle),
  `trace` (per cell) and `jobs` coalesce latest-wins; everything else must be
  delivered. bounded at 4096 frames / 64 MiB: coalescing frames go first, then
  the oldest, counted in the next hello's `dropped`. a daemon frame at or
  below the last seq applied is a replay and is dropped; each applied frame is
  acknowledged at once.
- **daemon side** (`python/link.gleam`, tables from the python extension's
  `kernel_links` schema migration): `kernel_links` (one row per session: kernel
  id, token, run dir, workspace, modules, pid/pgid/leader, epoch, last seq
  sent, and the job groups it owns, rewritten as they change), `kernel_outbox` keyed (session, kernel, seq), bounded at 2048 frames /
  64 MiB per kernel, and `kernel_calls`. the port owner persists each frame
  before writing it, deletes what the kernel acknowledges, and acknowledges
  kernel frames within 100 ms. its own last-seen seq lives in memory: after a
  daemon restart it accepts everything the kernel resends, and the dedupe
  rules below make that safe.

dedupe:

- host call id: a call already running in this daemon is ignored (its reply
  goes out through the outbox); one answered already is ignored the same way;
  one an earlier daemon started without answering is answered
  `{ok: false, code: "unknown"}`, never run again. a call's row goes once the
  kernel acknowledges its reply.
- execute, by cell id: a finished cell (the newest 16) resends its `done`; a
  queued or running one is ignored. callers must not reuse cell ids.
- interrupt, reply, release are idempotent already. an interrupt for a cell
  still queued behind the loop is kept and cancels the cell as it starts;
  one for a cell the kernel no longer holds is dropped.
- what the kernel resends after a restart: job wakes are host calls
  (`jobs.completed`), so the call ledger covers them; `job_start`, `job`,
  and `jobs` only update ownership and observations, which converge; a `done`
  nobody waits for rewrites the same outcome; traces save by cell id.

## drops

- the connection drops (the relay's socket closes, or the bridge dies): the port owner reattaches with backoff (50 ms doubling to
  2 s, 40 tries); exit 3 or a refusal means the kernel is gone and the old
  abandon path reaps it. a port owner attaching after a restart starts from
  the record's pid/pgid/leader and groups, so a kernel that died hard while
  nobody was attached still has its process group and its jobs' groups
  ended. the leader token (start time, from `/proc` or Darwin's `sysctl`)
  keeps a reused pid from being signalled. the cell keeps running meanwhile.
- the cell deadline passes, or an interrupt goes unanswered for 2 s, while
  detached: the interrupt waits in the outbox and the caller gets
  `kernel.Detached`, which leaves the journaled cell `started` (the model is
  told to check `cells.info`). a `done` that arrives for a cell nobody waits
  for any more is journaled through the `cells.finish` host route.
- the daemon crashes: its connection closes (a bridge sees EOF and exits); the kernel waits.
- graceful shutdown: `runtime.detach_kernels` first, so closing sessions and
  stopping the runtime let kernels go instead of ending them.
- daemon start: `runtime.resume_kernels` reattaches every recorded kernel in
  the background, one at a time through the boot slots, so late results and
  job wakes arrive without waiting for the session. a session that asks for
  its kernel meanwhile waits for that attach, and gets a fresh boot if there
  was nothing to attach to. an attached kernel's `runtime.origin` is
  `Resumed`, and the session keeps its namespace without the disk restore. a
  recorded kernel whose module set no longer fits is kept and marked stale; one
  in another workspace is stopped and replaced.

explicit drops still end the kernel at once: reset, release by the idle
sweep, `/cd`, session close, extension reloads (the replacement boots beside
the live kernel, never attached to it), and the old kernel after a swap.

## version skew

a kernel is stale when it runs another bundle than the bridge that reached it
(for a local kernel, the bundle the port owner hashed),
speaks another protocol (both read from the hello), or booted with another
module set than its session now has (found at reattach). `kernel.stale`
answers the reason and whether the swap was forced. `GET /sessions/{id}`
returns the native `kernel` observation with `instance_id`, `build`, `state`,
`stage`, `stale`, and `live_job_count`. Unknown identities and counts are null.
Reading this resource does not prepare or replace a kernel. `stage` reports
remote bundle staging while the owner is booting.

At the next idle moment, `session_namespace.ready` lets the runtime replace a
stale kernel when no live jobs keep it. The runtime does the work off its actor:

1. Snapshot the old namespace to `namespace.state` in its run directory.
2. Boot a replacement beside it. The replacement's identities, groups and
   outbox belong to `kernel_stages`; the old `kernel_links` row stays authoritative.
3. Check that the replacement is attached and current, then restore its namespace.
4. Mark the staged replacement ready, stop the old kernel and its jobs, and
   confirm that the old durable ownership record was removed.
5. Publish the replacement in `kernel_links` and adopt its actual handle.

Boot, validation or restore failure stops the staged candidate and keeps the
old kernel. A failed old-kernel stop reports the actual failure and attempts to
stop the staged candidate. Shutdown may already have affected jobs; the report
cannot promise to restore those external effects. Failed cleanup retains the
relevant durable identities for a later verified stop. No failed stop is reported
as a successful swap.

On restart, storage publishes a ready candidate if its old link is absent.
The daemon then supervises abandoned staged candidates before admitting work.
Staged owners use their immutable kernel ID throughout publication, so replies
and ownership updates continue to reach the same namespace.

The adopted kernel has origin `Upgraded`. The next model input names the carried
variables and definitions, and the transcript records the upgrade. A background
upgrade that cannot proceed keeps a usable old kernel and tries at a later idle
moment. A lost old kernel is reported as lost.

Live jobs keep an older bundle or module set until they end. `POST
/sessions/{id}/kernel/upgrade` is an explicit idle-session action that can stop
those jobs. Its response waits for the session to adopt the replacement and
reports actual old/new identities and builds, observed stopped job IDs, warnings,
and failure. An empty unattached session remains unchanged. There is no automatic
retry after a lost HTTP response; read the session kernel first. `/kernel upgrade`
uses this same operation, and `/kernel` reads the observation.

a kernel booted now that is already stale says this daemon and its own python
bundle disagree (a protocol bumped on one side only, a partial install): its
boot fails with that reason (`albedo_python:out_of_step/1`), so a turn waits
blocked on it instead of swapping one fresh kernel for another forever.

protocol skew does not wait for jobs: a kernel on another protocol cannot be
supervised. its outbox is dropped, not replayed; the swap asks for a snapshot
and a shutdown through the frozen frames, carries nothing if the snapshot
fails, and the stop's signal ladder ends the recorded process group either
way.

## lifetime

a kernel with nothing attached for its grace period reaps its job groups
(plugin cleanup) and exits, unless a job or cell is still live. the grace is
`ALBEDO_KERNEL_GRACE_SECONDS` read by the daemon (default 3600) and sent in
every attach; before its first attach a kernel waits 60 s. a kernel the
daemon reattached at start is attached, so the grace never runs out for it:
the maintenance sweep saves and stops one whose session has no loaded actor,
no live job or cell, and no turn within `ALBEDO_IDLE_SECONDS`. a kernel also
exits within a second of its run directory disappearing, which is how test
homes clean up after themselves. the e2e harness sets a 30 s grace, the gleam
test home 20 s.

## remote kernels

a session whose workspace is `[user@]host:/path` (workspaces.md) runs its
kernel on that host. nothing above the bridge changes: the outbox, reattach
with backoff and `resume_kernels` treat an ssh drop as a bridge that exited.

- **one ssh layer**: `priv/python/albedo_ssh.py` builds the argv (BatchMode,
  `ConnectTimeout=10`, `StrictHostKeyChecking=accept-new`,
  `ControlMaster=auto`, a `ControlPath` and `ControlPersist`), finds an
  agent socket, wraps commands in the remote login shell and stages the
  bundle. the model's `remote` plugin imports it, so the daemon and
  `remote.connect()` share masters and the staged bundle.
- **the user's masters**: when the user's ssh config names a `ControlPath`
  for the host (`ssh -G`, which reads no network), albedo uses that path and
  its `ControlPersist` (600 when it says no), so a master the user opened in
  a terminal carries albedo, and the master albedo opened carries the user's
  own ssh, colmena and git in `run` jobs: one sign-in (one hardware-key
  touch) per host. with none configured it is `/tmp/albedo-ssh-cm/%C` for
  600 s.
- **clean stdout**: every remote command is `/bin/sh -c 'exec 3>&1 1>&2;
  exec "$SHELL" -l -c "exec 1>&3 3>&-; <command>"'`, quoted with shlex in
  `albedo_ssh.in_login_shell` only. whatever the login profile prints (a
  motd, a greeting) goes to stderr, and the command gets the real stdout
  back, so the bridge's frames, the remote plugin's kernel and the probe's
  lines stay clean whatever the user's shell is.
- **fixed command lines**: the probe (and, with no network,
  `albedo_ssh.py commands <target> <home>`) answers the complete remote
  commands the daemon runs: `bridge` (`albedo_bridge.py --frame`), `signal`
  (`albedo_signal.py -`) and `remove`. their inputs go on stdin, never in
  the command line, so nothing in erlang quotes for a shell: the bridge's
  first frame is `{"bridge": {"argv": [start|attach, run_dir, modules?],
  "cwd": path}}` (exit 4 when `cwd` is no folder), the ladder reads its
  request line, `remove` the run directory.
- **probe** (`albedo_ssh.py probe <target>`, run by `albedo_ssh.erl`): one
  command over the master prints os, arch, home, cores, the python3 version
  and whether `~/.albedo-remote/<digest[:16]>` is staged; python older than
  3.11 is `unsupported`, a missing bundle is staged (tar over the same
  stream, unpacked beside the target and moved into place, so a bundle
  directory that exists is complete). ssh's own failure (exit 255) is
  `needs_auth` when its words say a person could get in (permission
  denied, host key verification, passphrase, keyboard-interactive),
  otherwise `unreachable`. answers are cached in the daemon, ready ones for
  a minute and failures for five seconds; a second caller joins a probe in
  flight. `albedo/harness/ssh.gleam` is the gleam face.
- **boot**: `kernel.place` probes (or reuses the cached probe) before the
  bridge starts, so a warmed host boots fast. the port owner runs the
  `bridge` command over ssh. a fresh boot's exit 4 reads as "not a folder
  there", 255 as an ssh failure. run directories live under the remote
  home, `~/.albedo-remote/run/<kernel id>`, recorded absolute.
- **a host out of reach is not a kernel gone**: only an attach the bridge
  ends with exit 3 (nothing at the run directory) or a refused attach
  proves a remote kernel gone. ssh failing (255), any other exit, or a
  startup timeout while attaching is a dropped connection: the session gets
  the kernel at once, reattaching, and the port owner keeps attaching in the
  background, backing off to every 30 s, until the kernel's grace (plus a
  minute) has surely passed since it lost the connection; then it forgets
  the record quietly, without reaching for the host. when the probe itself
  fails at boot, a recorded kernel is attached with commands rebuilt from
  its run directory (which names the home), so a wifi blip during a daemon
  restart keeps the namespace. a turn in a session with a kernel on record
  goes through while its host is unreachable or needs a sign-in, waiting
  like any reattach. only a fresh boot needs the host now.
- **ownership**: the pids a remote kernel declares are that host's. the
  `albedo_signal.py` ladder for its kernel and job groups runs there over
  ssh (the `signal` command, 15 s), never
  locally; if ssh can't reach the host the targets are left to the kernel's
  own grace exit, which reaps its jobs on the host, and the error says so.
  only the bridge (a local ssh client) is ever signalled here. the run
  directory goes with `rm -rf` over ssh. `os_pid` answers nothing for a
  remote kernel, so the reaper's `ps` never reads an unrelated local pid.
- **turns**: a session that holds a kernel (attached, or reattaching
  through its outbox) never probes on a turn. one that must boot probes
  for up to 3 s: still warming is left to the boot, which waits for the
  probe; `needs_auth`, unreachable or unsupported leave the turn admitted
  and waiting, blocked with the probe's words as its receipt's
  `blockingReason`, retried every 15 s like any blocked input
  (operations.md).
- **the model** gets a context line (python extension, `place.gleam`):
  "your python kernel and run jobs execute on chernobog (Linux aarch64)…",
  with the remote home.

### Host probes

`GET /hosts?target={host}` reads cached SSH probe state.
`POST /hosts/{host}/probe` starts or joins a bounded probe and returns `202`.
The client polls the read until it reaches a terminal state. Probe state includes
safe diagnostics and authentication instructions when operator sign-in is needed.
The same probe supports remote folder gathering. See the
[HTTP contract](../docs/http-api-design.md#models-workspaces-hosts-and-provider-login)
for the wire format and [workspaces](workspaces.md#browsing) for folder browsing.

### signing in

BatchMode stays on for the daemon. when a remote session's waiting turn is
blocked, the chat asks `GET /hosts?target={host}`; if that says `needs_auth` and the
daemon shares the tui's machine, the chat offers ctrl+l: it runs
`ssh -M -fN -o ControlPath=<control_path> -o ControlPersist=600 <host>`
through `tea.ExecProcess`, so ssh asks in the terminal, then warms the host,
and the waiting turn starts on the daemon's next try; the daemon rides that
master from then on. with a daemon elsewhere the notice says to run
`ssh <host>` on its machine, which carries the daemon when the user's ssh
config multiplexes that host. the offer goes once the turn starts or goes
away, or the session moves.

## not yet

- profile output a remote login shell prints reaches the daemon's own
  stderr log on every remote command.
