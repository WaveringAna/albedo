//// Progressive Agent Skills extension.
////
//// Each opened runtime session gets one immutable metadata snapshot. That same
//// snapshot drives prompt context, Python RPC, and user slash activation.

import albedo/harness/extension as harness_extension
import albedo/harness/skills/catalog
import albedo/harness/skills/rpc
import gleam/result

pub fn extension() -> harness_extension.Extension {
  extension_at(catalog.native_home())
}

/// Explicit home keeps integration tests and embedders isolated.
pub fn extension_at(home: String) -> harness_extension.Extension {
  harness_extension.Extension(
    "skills",
    "Discover Agent Skills metadata and activate selected instructions or resources on demand.",
    ["python"],
    [
      harness_extension.ManagedPlugin(fn(_, _, workspace) {
        use snapshot <- result.try(catalog.scan_at(workspace, home))
        Ok(
          harness_extension.Managed(
            catalog.context(snapshot),
            "Agent Skills are exposed through the async Python `skills` object. Use `await skills.list()` for this session's immutable metadata catalog, `await skills.activate(name, arguments)` to load one full SKILL.md into the current Python result, `await skills.resources(name)` to list resource names, and `await skills.read(name, resource=..., offset=..., limit=...)` for bounded content. Activation returns data only; it never submits another turn or executes bundled scripts.",
            [],
            ["skills"],
            [#("skills", fn(_, _, request) { rpc.handle(snapshot, request) })],
            fn() { Nil },
          ),
        )
      }),
    ],
    fn(_) { Ok(Nil) },
  )
}

/// Compatibility helpers for embedders and direct tests. Runtime sessions use the
/// immutable snapshot prepared above rather than calling these again.
pub fn discover_at(workspace: String, home: String) {
  catalog.scan_at(workspace, home)
  |> result.map(fn(snapshot) { #(snapshot.skills, snapshot.diagnostics) })
}

pub fn catalog_at(workspace: String, home: String) {
  catalog.scan_at(workspace, home) |> result.map(catalog.context)
}
