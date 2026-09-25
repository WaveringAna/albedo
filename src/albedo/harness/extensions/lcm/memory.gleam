//// Durable LCM fold retrieval remains available across strategy changes.

import albedo/harness/extension
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/tools

pub fn extension() -> extension.Extension {
  extension.Extension(
    "lcm-memory",
    "Read stored LCM folds and their transcript sources",
    [],
    [
      extension.ToolPlugin(
        "Stored LCM folds can remain after a compaction strategy changes. Use lcm_list to find every fold in this session, lcm_describe to inspect a fold, lcm_grep to search prior text, and lcm_expand to read bounded pages of original transcript rows. Summaries may omit details; check their sources when needed.",
        tools.definitions(),
        [],
        [],
      ),
    ],
    graph.initialise,
  )
}
