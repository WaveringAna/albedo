//// Remote kernels: the session's tools on another machine over SSH.

import albedo/harness/extension as harness_extension

pub fn extension() -> harness_extension.Extension {
  harness_extension.python_module(
    "remote",
    "Run this session's Python kernel on a remote host over SSH; every tool is callable on it.",
    "remote",
    "remote.connect(host) is ssh for this kernel: to work on another machine, use it"
      <> " instead of run(\"ssh\", host, command). rem = await remote.connect(\"deploy@box\")"
      <> " takes what ssh takes (an ~/.ssh/config alias, user@host:/abs/cwd, or"
      <> " ssh://user@host:port/abs/cwd) and signs in once for the whole connection, where"
      <> " each raw ssh job may sign in again (for the user, a hardware-key touch each)."
      <> " rem.run is run() on that host, pipes included, and its jobs wake the session like"
      <> " local ones: job = rem.run(\"journalctl\", \"-u\", \"nginx\", \"--no-pager\").pipe(\"rg\","
      <> " \"error\"); await job; job.tail(lines=40). Every other tool runs there too and"
      <> " crosses the network, so await it even where the local call is synchronous:"
      <> " await rem.files.read(path), await rem.files.find(...), await job.head(lines=20);"
      <> " job.tail() and job.exit_code answer without one. await rem.read(path) and"
      <> " await rem.write(path, content) move one file (read returns text, or bytes for"
      <> " a file that is not UTF-8; write takes either), await rem.show_image(path) shows"
      <> " a remote image, await rem.tools() lists what is there, and rem.work and rem.skills"
      <> " reach this session's daemon. If connect says the host needs a person to sign"
      <> " in, give the user the command it names. If python can't start there, connect"
      <> " warns and leaves rem.run plus rem.shell(\"cmd | cmd\"). remote.configure(host)"
      <> " sets the default target (else $ALBEDO_SSH, or the \"remote\" section of"
      <> " extensions.json); remote.connections() lists connections, and await rem.close()"
      <> " and await remote.close_all() end them. A dropped connection stays dropped:"
      <> " connect again. Failures raise RemoteError.",
    ["python"],
  )
}
