export type SkillCommand = {
  name: string
  description: string
  command: string
  source: string
}

export type SkillCatalog = {
  skills: SkillCommand[]
  diagnostics: string[]
}

export type SkillInvocation = {
  skill: SkillCommand
  arguments: string
}

const commandPattern = /^\/[^\s]+/

export function parseSkillCatalog(value: unknown): SkillCatalog {
  if (!value || typeof value !== "object") throw new Error("daemon returned invalid skills catalog")
  const raw = value as { skills?: unknown; diagnostics?: unknown }
  if (!Array.isArray(raw.skills) || !Array.isArray(raw.diagnostics))
    throw new Error("daemon returned invalid skills catalog")
  const skills = raw.skills.map(item => {
    if (!item || typeof item !== "object") throw new Error("daemon returned invalid skill metadata")
    const skill = item as Partial<SkillCommand>
    if (typeof skill.name !== "string" || typeof skill.description !== "string" ||
        typeof skill.command !== "string" || !/^\/(?:[a-z0-9]+(?:-[a-z0-9]+)*|skill:[a-z0-9]+(?:-[a-z0-9]+)*)$/.test(skill.command) ||
        typeof skill.source !== "string") throw new Error("daemon returned invalid skill metadata")
    return skill as SkillCommand
  })
  if (!raw.diagnostics.every(item => typeof item === "string"))
    throw new Error("daemon returned invalid skill diagnostics")
  return { skills, diagnostics: raw.diagnostics as string[] }
}

/** Built-ins run first in App; this resolves only exact daemon-assigned commands. */
export function parseSkillInvocation(value: string, catalog: SkillCatalog): SkillInvocation | undefined {
  const token = value.match(commandPattern)?.[0]
  if (!token) return undefined
  const skill = catalog.skills.find(item => item.command === token)
  if (!skill) return undefined
  const rest = value.slice(token.length)
  return { skill, arguments: /^\s/.test(rest) ? rest.slice(1) : rest }
}
