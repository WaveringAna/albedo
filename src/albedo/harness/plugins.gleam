import albedo/harness/bash
import albedo/harness/compaction
import albedo/harness/plugin
import albedo/harness/python
import albedo/harness/work
import gleam/option.{type Option, None}

/// Tool plugins compose; compaction has exactly one optional owner.
pub type Config {
  Config(tools: List(plugin.Plugin), compaction: Option(compaction.Strategy))
}

pub fn defaults() -> Config {
  Config([python.plugin(), bash.plugin(), work.plugin()], None)
}
