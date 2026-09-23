import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.python_module(
    "files",
    "Read, search, and exactly edit workspace files from Python.",
    "files",
    "files.read(path, start_line=, end_line=, limit=) returns complete numbered lines; limit counts lines, and a separate max_chars= budget (default 16000 characters) stops very large windows and says where to resume, files.ls(path) lists one directory, and files.edit(path, old, new) replaces one exact unique string, reporting every occurrence with line ranges when it is not unique; retry it with line_hint=<line>. These return immediately, and awaiting them also works. await files.find(pattern, path_or_paths, glob=, context=N) searches contents with N surrounding lines and await files.paths(pattern) searches names; both run a background search and must be awaited. Prefer these over shell equivalents, and start any other command with bash(command): never use subprocess, os.system, or os.popen, which spawn processes this session cannot supervise.",
    ["python", "bash"],
  )
}
