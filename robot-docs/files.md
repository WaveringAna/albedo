# files extension

`files` gives the model file vocabulary inside the Python session: bounded reads, one directory listing, exact edits, and search. It is enabled by default and depends on `python` and `run`.

Nothing here spawns a process directly. When ripgrep is installed, search runs as a supervised `run` job, so every child belongs to a job's process group and is ended with it. Without ripgrep the same calls fall back to pure Python. The internal search job is awaited and forgotten when it finishes; it does not appear in `jobs` or wake the session. If the cell is cancelled mid-search, its job is stopped before the cancellation continues.

```python
files.read("src/app.py", start_line=40, end_line=80)
files.ls("src")
files.edit("src/app.py", "def handler(request):", "def handler(request, *, trace):")
await files.find("prepare_history", "src", glob="*.gleam")
await files.paths("integration")
files.write("notes/plan.md", "...")
```

## read

`read(path, start_line=1, end_line=None, *, limit=None, max_chars=16000)` returns numbered lines. `limit` is a number of lines; `max_chars` is a separate character budget that keeps a huge window out of the context. A window stopped by either ends with which one stopped it and the line to resume from, so a large file is read in explicit steps rather than truncated silently. Lines are never shortened, and the numbers are the ones `edit(line_hint=)` accepts.

Reads decode UTF-8 with replacement and recognize Python line boundaries, including CRLF and Unicode separators. Scanning uses 64 KiB chunks and bounds memory by the chunk size and `max_chars`, even for giant lines. An open-ended read scans to EOF to report exact remaining line counts; an explicit `end_line` can stop scanning after that line.

## edit

`edit(path, old_str, new_str, line_hint=None)` replaces one exact, unique occurrence:

- The file is read with its identity (device, inode, mode, size, mtime), written to a temporary file with the same mode, and published with `os.replace` only while that identity still matches. A concurrent change fails the edit instead of overwriting it.
- A string that does not appear reports the closest candidates with line numbers and a similarity score. When the text is there and only whitespace differs (indentation, tabs, trailing spaces, line endings) the message says so first. `cells.run` replacements say the same.
- A string that appears several times changes nothing and lists every occurrence's line range with numbered context. Retry with `line_hint=<a line inside the range you want>`, or widen `old_str`. A hint only chooses between exact occurrences; it never moves the edit elsewhere.

`write(path, content)` replaces a whole file and creates parent directories, for new files rather than edits.

## search

`await find(pattern, path=".", glob=..., context=0, max_results=50, literal=False, case_sensitive=None, hidden=False)` searches contents and returns rows that print as `path:line: text`. `path` may be a list of paths. `context=N` adds up to N lines around each match, printed grep-style as `path-line- text` and marked `context=True`; `max_results` counts matches, not context lines. Slicing or indexing before the await applies to the rows, so `await find(...)[:10]` reads as intended. `await paths(pattern=None, path=".", glob=...)` searches file names; like `find`, `path` and `glob` may each be a list. A pattern with `*`, `?` or `[` globs the file name, or the path from the search root when it has a `/` (`src/*/*_test.go`; a leading `./` is optional). Returned paths carry no leading `./`. Both bound their results and say when the list was cut.

## await

`read`, `ls`, `edit`, and `write` return their result immediately, and that result may also be awaited: `files.read(path)` and `await files.read(path)` are the same call. `find` and `paths` run a background search, so they must be awaited; using one without `await` prints, or raises on iteration, a message saying so rather than a coroutine.
