//// Deprecated compatibility helpers. New code uses albedo/harness/extension.

import albedo/harness/extension

pub fn python_module(
  name: String,
  module: String,
  instructions: String,
) -> extension.Extension {
  extension.python_module(name, name, module, instructions, ["python"])
}
