//// Autoload project conventions and user preferences from common agent instruction files.

import albedo/harness/extension as harness_extension
import albedo/harness/instruction_files
import gleam/result

pub fn extension() -> harness_extension.Extension {
  extension_at(instruction_files.home())
}

/// Explicit home keeps tests and embedders isolated from the process environment.
pub fn extension_at(home: String) -> harness_extension.Extension {
  harness_extension.Extension(
    "instructions",
    "Autoload AGENTS.md, CLAUDE.md, and Markdown instructions from project and user agent directories.",
    [],
    [
      harness_extension.ManagedPlugin(fn(_, session, workspace) {
        use #(context, warnings) <- result.try(instruction_files.load_selected(
          workspace,
          home,
          session,
        ))
        Ok(
          harness_extension.Managed(
            ..harness_extension.empty(),
            context: context,
            warnings: warnings,
          ),
        )
      }),
    ],
    harness_extension.no_initialise,
  )
}
