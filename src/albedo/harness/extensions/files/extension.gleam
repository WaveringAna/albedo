import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.python_module(
    "files",
    "Read, search, and exactly edit workspace files from Python.",
    "files",
    "files.read(path, start_line=, end_line=, limit=) returns complete numbered lines; limit counts lines, and a separate max_chars= budget (default 16000 characters) stops very large windows and says where to resume, files.ls(path, pattern=) lists one directory, files.write(path, content) creates or replaces a whole file, and files.edit(path, old, new) replaces one exact unique string, reporting every occurrence with line ranges when it is not unique; retry it with line_hint=<line>. These return immediately, and awaiting them also works. await files.find(pattern, path_or_paths, glob=, context=N, literal=, case_sensitive=, max_results=50) searches contents (a regex unless literal=True) with N surrounding lines and await files.paths(pattern) searches names; both run a background search and must be awaited. Prefer these over shell equivalents, and start any other command with bash(command). subprocess, os.system, and os.popen are not blocked, but what they start is unsupervised: it is not stopped with the session or a timeout, keeps no retained output, and never wakes you, so use bash instead.",
    ["python", "bash"],
  )
}
