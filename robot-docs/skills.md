# Skills extension

Persisted preferences are owned by the daemon and changed through the [settings API](settings.md). The CLI refreshes them on use and never writes settings files.


Albedo's `skills` extension implements progressive disclosure for the [Agent Skills specification](https://agentskills.io/specification). It advertises only each valid skill's `name`, `description`, installed local `SKILL.md` path, and slash command. The model or user loads a full skill only through explicit activation.

## Discovery

The extension scans immediate child directories in this order:

1. `<workspace>/.albedo/skills`
2. `<workspace>/.agents/skills`
3. `~/.albedo/skills`
4. `~/.agents/skills`
5. `priv/skills` in the install: skills shipped with albedo (currently `customize-albedo`)

A valid workspace skill wins over a user skill with the same frontmatter `name`, and either replaces a built-in one without a diagnostic. Earlier roots win within the same scope. Entries and the final catalog are sorted deterministically. Invalid metadata and collisions appear as bounded catalog diagnostics rather than disappearing silently.

`.agents/skills` is the portable Agent Skills location. `.albedo/skills` is the Albedo-native location. A built-in skill is an ordinary skill directory under `priv/skills/`, so it needs no code: add the directory and it is cataloged, can be toggled as a `skills` capability, and is read through the same `skills.read` and `commands` paths.

Each immediate child must contain a `SKILL.md` that resolves to a regular file. The discovered child directory name and frontmatter `name` must match, even when the directory points to a package store path with a different name. Albedo requires the specification's `name` and `description` fields and accepts the optional `license`, `compatibility`, `metadata`, and `allowed-tools` fields. Optional fields are not advertised eagerly. YAML folded and multiline descriptions are supported through `yamerl`'s failsafe schema.

Discovery directories, individual skill directories, `SKILL.md`, and resources may be absolute or relative symlinks to any local location the daemon can read. This supports shared installations and Nix store layouts without copying their files. Broken links, link cycles, unreadable targets, and invalid metadata produce bounded diagnostics without blocking other skills.

Discovery is bounded to 128 candidates, 64 diagnostics, 64 KiB of frontmatter per file, and 1 MiB per `SKILL.md`. A catalog never includes the Markdown body or resource content.

The catalog is prepared once when a runtime session opens. Its immutable snapshot is shared by prompt context, session commands, Python RPC, and user slash activation. Changes on disk take effect after the skills extension or session is reloaded, or immediately through `/reload session`, which re-runs discovery and swaps the snapshot in place: the kernel, its Python namespace, and `skills` RPC routes rebind without a restart, and the refreshed catalog reaches prompt context, the command menu, and Python in the same swap. This prevents a UI lookup from seeing a different skill set than the model. New skills gained by a reload are reachable through `commands.catalog()` and `commands.invoke` right away; the typed `commands.<method>` bindings minted at kernel boot are not re-minted, so a skill added mid-session is invoked by name.

## Management catalog

`GET /sessions/{session_id}/catalog` discovers skills and instruction files in the daemon's session workspace and home directories. It includes disabled, invalid, and shadowed candidates, with source paths and validation diagnostics. For skills, `source` is the installed `SKILL.md` path and `resolved_source` is its actual target. Skill preference keys remain frontmatter names; each installed source has a separate stable row ID so duplicates remain distinguishable when links are retargeted.

The management catalog reports global preferences, session overrides, and effective enablement separately. Its revision changes with bounded instruction content, resolved directory and instruction targets, and preferences; catalog updates must use the observed revision. Reading it does not reload extensions or change the session's prepared prompt. A disabled winning skill does not expose a lower-priority duplicate.

The session resource (`GET /sessions/{session_id}`, which the TUI polls for status and glances) reports `selection.effective` and `composition` from the last discovery: it rereads saved choices and settings on every read, but walks skill, instruction, and MCP files only when the choices or settings change, when the catalog is read, or on a reload. A skill added on disk shows up there after `/reload session`.

## Activation and Python API

The `skills` extension depends on the `python` extension. It does not advertise separate model function tools. Every cataloged skill is a session command (see [commands](commands.md)): the kernel mints one typed method per skill from the same catalog the CLI menu shows. A model invocation reads the selected full `SKILL.md` and returns `name`, `description`, `source`, exact `arguments`, and `instructions` to the current Python call, without submitting or committing another turn; a user invocation submits exactly one activation turn.

```python
await commands.demo("merge these files")
await skills.resources("demo")
await skills.read("demo", "references/formats.md", offset=0, limit=16384)
```

`commands.catalog()` lists this session's commands (skills and built-ins) with argument details, and `commands.invoke("/demo", arguments)` runs one by slash name. The session pins the resolved skill directory and instruction target, including their filesystem identities. Activation and resource access require reload if either target changes, either object is replaced, or required metadata changes. In-place instruction body edits remain readable without reload. Reload discovers the current targets.

`skills.resources(name)` lists resource names beneath the installed skill directory without loading their contents. If only `SKILL.md` points elsewhere, sibling `references/` and `assets/` remain resources of that installed directory. Linked files and directories appear under their installed relative names, including separate aliases to the same directory. The listing returns at most 512 files, traverses at most 2,048 entries and 16 directory levels, skips links back to ancestor directories, and reports cycles, unreadable targets, or invalid resources as diagnostics.

`skills.read(name, resource, offset, limit)` reads one bounded byte range. `resource` defaults to `SKILL.md`, `offset` to `0`, and `limit` to `16384`; the maximum page is `65536` bytes. The result includes `next_offset`, `truncated`, total `size`, and `encoding`. UTF-8 pages are returned directly. Other bytes are base64. A readable resource cannot exceed 16 MiB.

Activation returns the installed `SKILL.md` path as `source`. Relative paths in skill instructions use its containing directory. Resource links resolve when listed or read, so changing a resource link does not require reload.

## Slash commands

The official client guide recommends user-explicit activation through a slash command or mention, while leaving the exact syntax to the client. Albedo assigns `/<skill-name>` and includes it in command autocomplete. Built-in commands always win. A colliding skill such as `model` gets the deterministic command `/skill:model` instead of replacing `/model`.

The CLI resolves an invocation against the daemon's [command catalog](commands.md), whose `skill` flag identifies skill entries. It submits a dedicated skill activation through the events route with a stable operation ID. The daemon uses the selected entry's `skill_activation` preparation function, shared with the existing command implementation. It stores the resolved instructions with the admission, so a retry or restart does not reread changed skill content. The visible intent remains the original slash command while the model input carries a JSON-delimited activation with the exact arguments, source, and instructions. See [operation receipts](operations.md) for recovery and retention.

## Trust and execution

The selected Albedo workspace is already trusted for model-driven code execution. When enabled, the skills extension reads metadata from that workspace and the listed user roots. It does not create a separate filesystem sandbox.

Reading or activating a skill never executes its scripts, imports its Python modules, fetches remote links, enables tools, or grants permissions. `allowed-tools` is descriptive metadata only. References, scripts, and assets are ordinary resources that require an explicit `skills.read` call. Remote URLs remain text for the model to consider; the extension does not fetch them.

Resource requests must use relative paths without parent traversal. Their symlink targets may lie outside the skill directory or discovery directory. Normal daemon filesystem permissions still apply.

Disabling the extension removes its catalog, instructions, Python module, RPC route, and slash commands together for that session. It does not stop another enabled capability, such as Python, from reading files it is already authorized to access.

## YAML dependency

Albedo uses `yamerl` 0.10.x under its BSD-2-Clause license. Parsing selects the failsafe schema, supplies no custom node modules, rejects unknown tags, and does not construct Erlang atom or function tags from skill metadata.
