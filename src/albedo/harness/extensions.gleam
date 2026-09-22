import albedo/harness/bash
import albedo/harness/extension
import albedo/harness/files
import albedo/harness/mcp
import albedo/harness/models
import albedo/harness/python
import albedo/harness/rolling
import albedo/harness/skills
import albedo/harness/ssh
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
      skills.extension(),
      models.extension(),
      rolling.extension(),
      mcp.configured_extension(),
      ssh.extension(),
    ],
    ["python", "bash", "work", "files", "skills", "models", "rolling"],
  )
}
