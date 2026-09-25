import albedo/harness/extension
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/extensions/bash/extension as bash
import albedo/harness/extensions/codex/extension as codex
import albedo/harness/extensions/commands/extension as commands
import albedo/harness/extensions/files/extension as files
import albedo/harness/extensions/instructions/extension as instructions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/memory as lcm_memory
import albedo/harness/extensions/mcp/extension as mcp
import albedo/harness/extensions/models/extension as models
import albedo/harness/extensions/openai/extension as openai
import albedo/harness/extensions/proxy/extension as proxy
import albedo/harness/extensions/python/extension as python
import albedo/harness/extensions/remote/extension as remote
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/schedule/extension as schedule
import albedo/harness/extensions/skills/extension as skills
import albedo/harness/extensions/view/extension as view
import albedo/harness/extensions/webhooks/extension as webhooks
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
      schedule.extension(),
      files.extension(),
      instructions.extension(),
      commands.extension(),
      skills.extension(),
      // Ahead of models.dev: it answers only for its own endpoint, where a
      // shared id such as claude-sonnet-4-6 has Antigravity's limits.
      antigravity.extension(),
      models.extension(),
      openai.extension(),
      codex.extension(),
      rolling.extension(),
      lcm_memory.extension(),
      lcm.extension(),
      mcp.configured_extension(),
      remote.extension(),
      view.extension(),
      proxy.extension(),
      webhooks.extension(),
    ],
    [
      "python", "bash", "work", "schedule", "files", "instructions", "commands",
      "skills", "models", "openai", "codex", "antigravity", "rolling",
      "lcm-memory", "remote",
    ],
  )
}
