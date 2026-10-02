# the detached kernel

a session's python kernel (`priv/python/albedo_kernel.py`) is its own process,
detached from the daemon: it outlives a dropped connection and a daemon
restart, keeping its namespace and its background jobs. the daemon reaches it
through a bridge, and every message between the two travels through a small
session layer that neither loses nor repeats a message across a reconnect.

## processes

- **kernel**: started in its own session and process group, stdio not tied to
  anyone. it listens on `kernel.sock` in its run directory,
  `$ALBEDO_HOME/run/<kernel id>/` (0700; the socket is bound relative to the
  directory so a long temp home stays under the ~104-byte `sun_path` limit).
  `kernel.log` there catches what it writes before its own output capture
  starts.
- **bridge** (`priv/python/albedo_bridge.py`): what the daemon's erlang port
  runs now, with the same `{packet, 4}` stdio framing the kernel used to have.
  `start <run_dir> <modules-json>` starts the kernel beside it (the token goes
  over the kernel's stdin, never argv) and waits for its socket;
  `attach <run_dir>` connects to a running one. it announces its own bundle
  hash (`{"bridge": {"bundle"}}`), then copies bytes both ways until either
  side closes. exit status 3 means no kernel is there. killing it never
  touches the kernel. a remote kernel's bridge is the same argv run over ssh
  (see remote kernels below).
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
held, external, slots, dropped}}`, or `{"refused": reason}`. `protocol` (1) and the
hello/snapshot/shutdown frames never change shape. `bundle` is
`albedo_bundle.digest()`, the same content hash the remote plugin stages
under; a hello whose bundle or protocol differs from the bridge's makes the
kernel stale (see version skew). `jobs` (live `job_start` frames), `external`,
`held` (jobs granted a heavy slot whose end isn't proven yet) and `slots` (job
slots still waited for) let a fresh port owner take over job ownership and
admission: held slots count in its pool at once (`albedo_job_slots:claim`,
even past the limit), waited-for ones are asked for again.

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
  `job_cancel` and `jobs` only update ownership and slot bookkeeping, which
  converges; `job_acquire` asks the new pool, which never saw it; a `done`
  nobody waits for rewrites the same outcome; traces save by cell id.

## drops

- the bridge dies: the port owner reattaches with backoff (50 ms doubling to
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
- the daemon crashes: the bridge sees EOF and exits; the kernel waits.
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

a kernel is stale when it runs another bundle than the bridge that reached it,
speaks another protocol (both read from the hello), or booted with another
module set than its session now has (found at reattach). `kernel.stale`
answers the reason and whether the swap was forced; the session status carries
`kernel: {stale, reason?, link, step?}`, and the tui shows `kernel older` beside the
header counts. `link` is how the session reaches its kernel: `none` before it
needed one, `booting` while one opens (or a daemon start's attach is awaited),
`attached`, `reattaching` while the bridge is down and the port owner retries
(`albedo_python:linked/1`), and `lost` once it gave up. the tui fades a remote
host in the header while booting or reattaching, and colors it as an error
once lost. `step` is `staging` while a remote kernel's boot waits for its
host's probe to copy the bundle over, so the status line can say `copying
the kernel to chernobog…` instead of `connecting to chernobog…`.

the swap happens at the session's next idle moment: `session_namespace.ready`,
which every turn, compaction and background call goes through, lets go of a
kernel that `runtime.upgradable` says nothing keeps, so the session asks the
runtime again (parking its work), and the runtime's open runs `kernel.upgrade`
off the actor while the session waits, as for a boot:

1. snapshot the old namespace to `namespace.state` in the old kernel's run
   directory (a kernel with a cell still running answers busy at once);
2. boot a fresh kernel on the current bundle and module set beside it;
3. restore into it from that file;
4. stop the old kernel, ending any jobs it still had, and its run directory.

the session adopts it with origin `Upgraded`: the model's next message carries
"The python kernel was upgraded to the new python bundle. Restored: a, b. Not
carried: x (why)." and the transcript a note. imports and definitions that
were not saved are gone, as after a disk restore. a swap that cannot happen
now (busy, a namespace that would not save) hands the old kernel back
(`Kept`), still stale, and the next idle moment tries again.

live jobs keep an older bundle or module set until they end (the job's wake
is usually that idle moment). `/kernel` reports the staleness and the live
jobs; `/kernel upgrade` (user only, between turns) forces the swap now,
stopping the jobs as a restart did before kernels were detached.

protocol skew does not wait for jobs: a kernel on another protocol cannot be
supervised. its outbox is dropped, not replayed; the swap asks for a snapshot
and a shutdown through the frozen frames, carries nothing if the snapshot
fails, and the stop's signal ladder ends the recorded process group either
way.

## lifetime

a kernel with nothing attached for its grace period reaps its job groups
(plugin cleanup) and exits, unless a job or cell is still live. the grace is
`ALBEDO_KERNEL_GRACE_SECONDS` read by the daemon (default 3600) and sent in
every attach; before its first attach a kernel waits 60 s. a kernel also
exits within a second of its run directory disappearing, which is how test
homes clean up after themselves. the e2e harness sets a 30 s grace, the gleam
test home 20 s.

## remote kernels

a session whose workspace is `[user@]host:/path` (workspaces.md) runs its
kernel on that host. nothing above the bridge changes: the outbox, reattach
with backoff and `resume_kernels` treat an ssh drop as a bridge that exited.

- **one ssh layer**: `priv/python/albedo_ssh.py` builds the argv (BatchMode,
  `ConnectTimeout=10`, `StrictHostKeyChecking=accept-new`,
  `ControlMaster=auto`, `ControlPath=/tmp/albedo-ssh-cm/%C`,
  `ControlPersist=600`), finds an agent socket, wraps commands in the
  remote login shell and stages the bundle. the model's `remote` plugin
  imports it, so the daemon and `remote.connect()` share masters and the
  staged bundle.
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
- **heavy slots**: a remote kernel's jobs queue in that host's own pool
  (`albedo_job_slots:ensure(Host, Cpus)`, started and watched by the local
  pool), sized to the cores the probe found (`ALBEDO_MAX_REMOTE_JOBS`
  overrides; two while a host attached without a probe is still unknown,
  corrected by the next probe) with no load adjustment; admission is the
  same protocol.
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

### `/hosts`

- `GET /hosts/:host` (`[user@]host`): the cached probe, or `warming` while
  one runs (a stale or missing answer starts one).
- `POST /hosts/:host/warm`: drops a cached answer and probes now, waiting up
  to a minute.

both answer `{host, state, detail}` with `state` one of `ready`, `warming`,
`needs_auth` (with `control_path`), `unreachable`, `unsupported`, and `os`,
`arch`, `home` when ready. a `warming` answer carries `step: "staging"` while
the probe copies the bundle: `albedo_ssh.py probe` prints `{"step":
"staging"}` on its own line first, and `albedo_ssh.erl` passes each line on
as it arrives (`albedo_ssh:step/1`), keeping the last line as the answer. `/health` lists `remote_hosts`. `GET /hosts`
(the picker's host completion) is in workspaces.md. the same probe also
answers the `gather` command the folder browser and project readers run.

### signing in

BatchMode stays on for the daemon. when a remote session's waiting turn is
blocked, the chat asks `GET /hosts/:host`; if that says `needs_auth` and the
daemon shares the tui's machine, the chat offers ctrl+l: it runs
`ssh -M -fN -o ControlPath=<control_path> -o ControlPersist=600 <host>`
through `tea.ExecProcess`, so ssh asks in the terminal, then warms the host,
and the waiting turn starts on the daemon's next try; the daemon rides that
master from then on. with a daemon elsewhere the notice says to run
`ssh <host>` on its machine. the offer goes once the turn starts or goes
away, or the session moves.

## not yet

- profile output a remote login shell prints reaches the daemon's own
  stderr log on every remote command.
