import albedo/harness/bash
import albedo/harness/extension
import albedo/harness/mcp
import albedo/harness/models
import albedo/harness/python
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
      skills.extension(),
      models.extension(),
      rolling.extension(),
      mcp.configured_extension(),
    ],
    ["python", "bash", "work", "skills", "models", "rolling"],
  )
}
