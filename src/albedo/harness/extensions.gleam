import albedo/harness/bash
import albedo/harness/codex
import albedo/harness/commands
import albedo/harness/extension
import albedo/harness/files
import albedo/harness/mcp
import albedo/harness/models
import albedo/harness/openai
import albedo/harness/python
import albedo/harness/remote
import albedo/harness/rolling
import albedo/harness/skills
import albedo/harness/work

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
      commands.extension(),
      skills.extension(),
      models.extension(),
      openai.extension(),
      codex.extension(),
      rolling.extension(),
      mcp.configured_extension(),
      remote.extension(),
    ],
    [
      "python", "bash", "work", "files", "commands", "skills", "models",
      "openai", "codex", "rolling", "remote",
    ],
  )
}
