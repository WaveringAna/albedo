//// Remote kernels: the session's tools on another machine over SSH.

import albedo/harness/extension as harness_extension

pub fn extension() -> harness_extension.Extension {
  harness_extension.python_module(
    "remote",
    "Run this session's Python kernel on a remote host over SSH; every tool is callable on it.",
    "remote",
    "remote.connect(host=None) boots this session's Python kernel on a remote host over"
      <> " one SSH connection (ControlMaster) and returns a connection handle: rem ="
      <> " await remote.connect(). Every harness tool is then callable on it. Machine tools"
      <> " run on the remote kernel: rem.run(program, *args) starts a supervised job there whose"
      <> " handle supports await, tail(), poll(), and stop(), as in rem = await"
      <> " remote.connect(\"devbox\"); job = await rem.run(\"git\", \"status\","
      <> " cwd=\"proj/albedo\"); job.tail(lines=20), or a pipe that runs entirely on the"
      <> " host: job = await rem.run(\"journalctl\", \"-u\", \"nginx\", \"--no-pager\").pipe(\"rg\","
      <> " \"error\"); job.tail(lines=40). tail(lines=) and exit_code answer from the mirror;"
      <> " other job methods are remote calls to await: await job.head(lines=20). await"
      <> " rem.files.read(...)"
      <> " and await rem.files.find(...) operate on the remote filesystem. Session tools"
      <> " run where the daemon runs: await rem.work.* and await rem.skills.* relay over"
      <> " the connection to this session's daemon. rem.run(...) starts the job"
      <> " immediately and synchronously, like local run: the handle exists right away,"
      <> " job.tail(), job.id, job.exit_code, job.duration, job.waited, and"
      <> " job.timed_out answer synchronously from the mirrored output stream,"
      <> " await job waits for completion, and await job.stop() stops it. A remote"
      <> " job that finishes with its result unread wakes the session by itself,"
      <> " naming the host it ran on; awaiting it, reading its result, or stopping"
      <> " it first means no wake. Every other call"
      <> " returns a reference that settles on its first await: await rem.files.find(...)"
      <> " resolves to its value, await rem.work.list() to the daemon's answer. Results"
      <> " cross as real objects, so remote output looks exactly like local output; a"
      <> " result that cannot cross is a live reference whose methods are further remote"
      <> " calls, and references passed back into remote calls stay references rather than"
      <> " becoming copies. A call whose local counterpart is synchronous (rem.files.read)"
      <> " still needs await, because the value itself crosses the network; handles and"
      <> " their state never do. await rem.tools() lists what the remote namespace holds;"
      <> " await rem.read(path) and await rem.write(path, content) move one file's text"
      <> " directly, and await rem.show_image(path_or_bytes) returns a remote image with"
      <> " this cell's result under the same limits as show_image. remote.connections() lists open connections (awaiting it also works) and await"
      <> " remote.close_all() ends them all. Failures raise RemoteError."
      <> " The target resolves per call from a host="
      <> " argument, then remote.configure(host, remote_cwd=None), then $ALBEDO_SSH"
      <> " (user@host[:/path]), or the \"remote\" section of extensions.json (host,"
      <> " remoteCwd, python). If the host is reachable but its kernel cannot boot, the"
      <> " connection still returns, prints a warning, and answers only rem.run(program,"
      <> " *args, cwd=None, env=None, stdin=None, timeout=300), rem.read(path), rem.write(path,"
      <> " content), and rem.show_image(path_or_bytes). The degraded-mode warning gives an explicit rem.shell(command) escape"
      <> " hatch for pipes; it is unavailable in kernel mode. Degraded stdin takes only"
      <> " text or bytes, not a file or job; .pipe() is unavailable, and stopping SSH"
      <> " cannot prove the remote process stopped. Connections are"
      <> " scoped: a lost SSH channel invalidates the connection rather than silently"
      <> " reconnecting, and await rem.close() ends it.",
    ["python"],
  )
}
