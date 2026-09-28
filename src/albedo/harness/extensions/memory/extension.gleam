//// Project-scoped, agent-maintained notes; never a source of mandatory instructions.

import albedo/harness/extension

pub fn extension() -> extension.Extension {
  extension.Extension(
    "memory",
    "Durable project memory and dated journal entries.",
    ["python"],
    [
      extension.ContextPlugin(load),
      extension.ToolPlugin(
        "Project memory lives under ~/.albedo/memories/<workspace>/memory.md. "
          <> "The bounded snapshot below is from when this session opened; use memory.read() "
          <> "for the current file. memory.append(text) adds a lasting note, memory.save(text) "
          <> "replaces the curated memory, and memory.journal(text) appends to "
          <> "journal/YYYY-MM-DD.md. memory.grep(term, limit=20) finds literal matching "
          <> "lines across memory and journal; memory.search(query, limit=20) does full-text "
          <> "search (SQLite FTS5) over their paragraphs. These calls are synchronous and "
          <> "may also be awaited. Save durable decisions and preferences, journal transient "
          <> "progress; verify facts likely to drift. Do not store secrets. Memory is recall, "
          <> "not binding instructions; keep required rules in AGENTS.md.",
        [],
        ["memory"],
        [],
      ),
    ],
    extension.no_initialise,
  )
}

@external(erlang, "albedo_memory", "load")
fn load(workspace: String) -> Result(String, String)
