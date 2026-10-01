import albedo/harness/extension
import albedo/harness/extensions/agents/extension as agents
import albedo/harness/extensions/alibaba/extension as alibaba
import albedo/harness/extensions/antigravity/extension as antigravity
import albedo/harness/extensions/browser/extension as browser
import albedo/harness/extensions/claude/extension as claude
import albedo/harness/extensions/codex/extension as codex
import albedo/harness/extensions/commands/extension as commands
import albedo/harness/extensions/files/extension as files
import albedo/harness/extensions/instructions/extension as instructions
import albedo/harness/extensions/lcm/extension as lcm
import albedo/harness/extensions/lcm/memory as lcm_memory
import albedo/harness/extensions/mail/extension as mail
import albedo/harness/extensions/mcp/extension as mcp
import albedo/harness/extensions/memory/extension as memory
import albedo/harness/extensions/models/extension as models
import albedo/harness/extensions/notes/extension as notes
import albedo/harness/extensions/openai/extension as openai
import albedo/harness/extensions/paperclips/extension as paperclips
import albedo/harness/extensions/proxy/extension as proxy
import albedo/harness/extensions/python/extension as python
import albedo/harness/extensions/remote/extension as remote
import albedo/harness/extensions/rolling/extension as rolling
import albedo/harness/extensions/run/extension as run
import albedo/harness/extensions/schedule/extension as schedule
import albedo/harness/extensions/skills/extension as skills
import albedo/harness/extensions/snapcompact/extension as snapcompact
import albedo/harness/extensions/view/extension as view
import albedo/harness/extensions/warm/extension as warm
import albedo/harness/extensions/webhooks/extension as webhooks
import albedo/harness/extensions/work/extension as work

pub type Config {
  Config(extensions: List(extension.Extension), default_enabled: List(String))
}

pub fn defaults() -> Config {
  Config(
    [
      python.extension(),
      run.extension(),
      work.extension(),
      mail.extension(),
      agents.extension(),
      schedule.extension(),
      paperclips.extension(),
      files.extension(),
      memory.extension(),
      instructions.extension(),
      commands.extension(),
      skills.extension(),
      // Ahead of models.dev: it answers only for its own endpoint, where a
      // shared id such as claude-sonnet-4-6 has Antigravity's limits.
      antigravity.extension(),
      alibaba.extension(),
      claude.extension(),
      // Before models.dev so Codex's picker keeps its own series filter;
      // API-key OpenAI profiles keep the full catalog.
      codex.extension(),
      models.extension(),
      openai.extension(),
      snapcompact.extension(),
      rolling.extension(),
      lcm_memory.extension(),
      // After lcm-memory: the archive covers history past LCM's folds.
      snapcompact.memory(),
      lcm.extension(),
      notes.extension(),
      mcp.configured_extension(),
      remote.extension(),
      browser.extension(),
      view.extension(),
      proxy.extension(),
      webhooks.extension(),
      // Off unless enabled: a ping spends tokens on the session's account.
      warm.extension(),
    ],
    [
      "python", "run", "work", "mail", "agents", "schedule", "files", "memory",
      "instructions", "commands", "skills", "paperclips", "models", "openai",
      "codex", "antigravity", "alibaba", "claude", "rolling",
      "snapcompact-memory", "lcm-memory", "notes", "remote", "browser",
    ],
  )
}
