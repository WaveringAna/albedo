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
  touches the kernel. #56 runs the same argv over ssh.
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
external, slots, dropped}}`, or `{"refused": reason}`. `protocol` (1) and the
hello/snapshot/shutdown frames never change shape. `bundle` is
`albedo_bundle.digest()`, the same content hash the remote plugin stages
under; a hello whose bundle or protocol differs from the bridge's is only
logged for now (#55 acts on it). `jobs` (live `job_start` frames), `external`
and `slots` (job slots still waited for) let a fresh port owner take over job
ownership and admission.

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
  sent), `kernel_outbox` keyed (session, kernel, seq), bounded at 2048 frames /
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
- interrupt, reply, release are idempotent already.

## drops

- the bridge dies: the port owner reattaches with backoff (50 ms doubling to
  2 s, 40 tries); exit 3 or a refusal means the kernel is gone and the old
  abandon path reaps it. the cell keeps running meanwhile.
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
  was nothing to attach to. an attached kernel is `runtime.resumed`, and the
  session keeps its namespace without the disk restore. a recorded kernel
  whose workspace or module set no longer fits is stopped and replaced (#55
  will swap it at idle instead).

explicit drops still end the kernel at once: reset, release by the idle
sweep, `/cd`, session close, extension reloads (the replacement boots beside
the live kernel, never attached to it).

## lifetime

a kernel with nothing attached for its grace period reaps its job groups
(plugin cleanup) and exits, unless a job or cell is still live. the grace is
`ALBEDO_KERNEL_GRACE_SECONDS` read by the daemon (default 3600) and sent in
every attach; before its first attach a kernel waits 60 s. a kernel also
exits within a second of its run directory disappearing, which is how test
homes clean up after themselves. the e2e harness sets a 30 s grace, the gleam
test home 20 s.

## not yet

- after a daemon restart, job groups of a kernel that died hard (SIGKILL) while
  nobody was attached are not reaped: the recorded pid could be reused.
- job slots a reattached kernel's running jobs held are not re-counted in the
  new daemon's pool; only slots still waited for are asked for again.
