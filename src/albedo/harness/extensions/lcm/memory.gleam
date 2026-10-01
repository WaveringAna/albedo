//// Durable LCM fold retrieval remains available across strategy changes.

import albedo/harness/compaction
import albedo/harness/extension
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/graph
import albedo/harness/extensions/lcm/tools

pub fn extension() -> extension.Extension {
  extension.Extension(
    "lcm-memory",
    "Read stored LCM folds and their transcript sources",
    [],
    [
      extension.ToolPlugin(
        "Stored LCM folds can remain after a compaction strategy changes. Use lcm_list to find every fold in this session, lcm_describe to inspect a fold, lcm_grep to search prior text, and lcm_expand to read bounded pages of original transcript rows. Node ids come from lcm_list or lcm_grep; a transcript row seq is not a node id and belongs to transcript_read instead. Summaries may omit details; check their sources when needed.",
        tools.definitions(),
        [],
        [],
      ),
      // Other strategies see stored folds through their compaction context.
      extension.FoldPlugin(compaction.Folds("lcm", "lcm", lcm.stored_prior)),
    ],
    graph.initialise,
  )
}
