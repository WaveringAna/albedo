import albedo/harness/extension
import albedo/harness/extensions/bash/extension as bash
import albedo/harness/extensions/codex/extension as codex
import albedo/harness/extensions/commands/extension as commands
import albedo/harness/extensions/files/extension as files
import albedo/harness/extensions/instructions/extension as instructions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/mcp/extension as mcp
import albedo/harness/extensions/models/extension as models
import albedo/harness/extensions/openai/extension as openai
import albedo/harness/extensions/python/extension as python
import albedo/harness/extensions/remote/extension as remote
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/skills/extension as skills
import albedo/harness/extensions/view/extension as view
import albedo/harness/extensions/work/extension as work

pub type Config {
  Config(extensions: List(extension.Extension), default_enabled: List(String))
}

pub fn defaults() -> Config {
  Config(
    [
      python.extension(),
      bash.extension(),
      work.extension(),
      files.extension(),
      instructions.extension(),
      commands.extension(),
      skills.extension(),
      models.extension(),
      openai.extension(),
      codex.extension(),
      rolling.extension(),
      lcm.extension(),
      mcp.configured_extension(),
      remote.extension(),
      view.extension(),
    ],
    [
      "python", "bash", "work", "files", "instructions", "commands", "skills",
      "models", "openai", "codex", "rolling", "remote",
    ],
  )
}
