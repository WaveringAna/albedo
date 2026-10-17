//// Remote kernels: the session's tools on another machine over SSH.

import albedo/harness/extension as harness_extension
import albedo/harness/settings
import gleam/dynamic/decode

/// The kernel's Python reads these (`albedo_plugins/remote.py`); they are
/// declared here so the daemon can list and save them.
fn config_section() -> settings.Section(Nil) {
  settings.section(
    "remote",
    "Remote kernels over SSH",
    settings.Tools,
    [
      settings.field(settings.optional_text(
        "host",
        "Host",
        "Where remote.connect() goes without a host: an ~/.ssh/config alias, user@host[:/path], or ssh://user@host[:port][/path]. remote.configure() and $ALBEDO_SSH come first.",
      )),
      settings.field(settings.optional_text(
        "remoteCwd",
        "Remote directory",
        "The working directory on the host. Unset asks the host for its own.",
      )),
      settings.field(settings.optional_text(
        "python",
        "Python",
        "The Python 3.11 or newer the remote kernel runs with. Unset uses python3.",
      )),
    ],
    decode.success(Nil),
    Ok,
  )
}

pub fn extension() -> harness_extension.Extension {
  let module =
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
        <> " job.tail() and job.exit_code answer without one. Tail previews have the same"
        <> " 64 KiB window and explicit limits as local jobs."
        <> " Jobs spill automatically on their capture host, with the same 16 MiB disk cap."
        <> " await job.read(offset=0, limit=65536) pages the spill file past 1 MiB."
        <> " await job.read() returns complete text up to 1 MiB; await job.save(path) saves"
        <> " exact output bytes on that host. Both refuse incomplete output. In degraded"
        <> " SSH command mode, job.save(path) saves locally, where output is captured."
        <> " await rem.read(path) and"
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
  harness_extension.Extension(..module, plugins: [
    harness_extension.SettingsPlugin(settings.declaration(config_section())),
    ..module.plugins
  ])
}
