import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.python_module(
    "files",
    "Read, search, and exactly edit workspace files from Python.",
    "files",
    "files.read(path, start_line=, end_line=, limit=) returns complete numbered lines within a bounded result (increase limit for a long line), files.ls(path) lists one directory, and files.edit(path, old, new) replaces one exact unique string, reporting every occurrence with line ranges when it is not unique; retry it with line_hint=<line>. await files.find(pattern, path, glob=) searches contents and await files.paths(pattern) searches names. Prefer these over shell equivalents, and start any other command with bash(command): never use subprocess, os.system, or os.popen, which spawn processes this session cannot supervise.",
    ["python", "bash"],
  )
}
