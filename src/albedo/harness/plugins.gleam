import albedo/harness/bash
import albedo/harness/plugin
import albedo/harness/python
import albedo/harness/work

pub fn defaults() -> List(plugin.Plugin) {
  [python.plugin(), bash.plugin(), work.plugin()]
}
