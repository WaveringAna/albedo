# files extension

`files` gives the model file vocabulary inside the Python session: bounded reads, one directory listing, exact edits, and search. It is enabled by default and depends on `python` and `bash`.

Nothing here spawns a process directly. When ripgrep is installed, search runs as a supervised `bash` job, so every child belongs to a job's process group and is ended with it. Without ripgrep the same calls fall back to pure Python.

```python
files.read("src/app.py", start_line=40, end_line=80)
files.ls("src")
files.edit("src/app.py", "def handler(request):", "def handler(request, *, trace):")
await files.find("prepare_history", "src", glob="*.gleam")
await files.paths("integration")
files.write("notes/plan.md", "...")
```

## read

`read(path, start_line=1, end_line=None, limit=16000)` returns numbered lines. The numbers are the ones `edit(line_hint=)` accepts. A window that reaches the limit ends with the line to resume from, so a large file is read in explicit steps rather than truncated silently.

## edit

`edit(path, old_str, new_str, line_hint=None)` replaces one exact, unique occurrence:

- The file is read with its identity (device, inode, mode, size, mtime), written to a temporary file with the same mode, and published with `os.replace` only while that identity still matches. A concurrent change fails the edit instead of overwriting it.
- A string that does not appear reports the closest candidates with line numbers and a similarity score.
- A string that appears several times changes nothing and lists every occurrence's line range with numbered context. Retry with `line_hint=<a line inside the range you want>`, or widen `old_str`. A hint only chooses between exact occurrences; it never moves the edit elsewhere.

`write(path, content)` replaces a whole file and creates parent directories, for new files rather than edits.

## search

`await find(pattern, path=".", glob=..., max_results=50, literal=False, case_sensitive=None, hidden=False)` searches contents and returns rows that print as `path:line: text`. `await paths(pattern=None, path=".", glob=...)` searches file names. Both bound their results and say when the list was cut.
