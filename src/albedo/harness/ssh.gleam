//// Remote execution over SSH: one configured host answers commands and file reads.

import albedo/harness/extension as harness_extension

pub fn extension() -> harness_extension.Extension {
  harness_extension.python_module(
    "ssh",
    "Run commands and move files on a remote host over SSH.",
    "ssh",
    "ssh.run(command, host=None, timeout=None) executes on the remote host and"
      <> " returns {command, host, exit_code, stdout, stderr}; exit code 255 usually"
      <> " means the connection itself failed. ssh.read(path) returns remote file"
      <> " text and ssh.write(path, content) replaces it; workspace paths map onto"
      <> " the remote cwd. Resolve the target once with ssh.configure(host,"
      <> " remote_cwd=None), from $ALBEDO_SSH (user@host[:/path]), or from the ssh"
      <> " section of extensions.json.",
    ["python"],
  )
}
