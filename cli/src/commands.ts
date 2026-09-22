export type CommandArgument = {
  name: string
  description: string
  required: boolean
}

export type SessionCommand = {
  name: string
  description: string
  method: string
  arguments: CommandArgument[]
  modelCallable: boolean
  userTurn: boolean
}

export type CommandInvocation = {
  name: string
  arguments: string
}

const commandPattern = /^\/[^\s]+/

const commandNamePattern = /^\/(?:[a-z0-9]+(?:-[a-z0-9]+)*|skill:[a-z0-9]+(?:-[a-z0-9]+)*)$/

const methodPattern = /^[A-Za-z_][A-Za-z0-9_]*$/

export function parseCommandCatalog(value: unknown): SessionCommand[] {
  if (!Array.isArray(value)) throw new Error("daemon returned invalid command catalog")
  return value.map(item => {
    if (!item || typeof item !== "object") throw new Error("daemon returned invalid command metadata")
    const command = item as Partial<SessionCommand>
    const args = command.arguments
    const validArgs = Array.isArray(args) && args.every(argument => {
      if (!argument || typeof argument !== "object") return false
      const item = argument as Partial<CommandArgument>
      return typeof item.name === "string" && typeof item.description === "string" &&
        typeof item.required === "boolean"
    })
    if (typeof command.name !== "string" || !commandNamePattern.test(command.name) ||
        typeof command.description !== "string" ||
        typeof command.method !== "string" || !methodPattern.test(command.method) ||
        !validArgs ||
        typeof command.modelCallable !== "boolean" || typeof command.userTurn !== "boolean")
      throw new Error("daemon returned invalid command metadata")
    return command as SessionCommand
  })
}

/** Built-ins run first in App; this resolves only exact daemon-assigned commands. */
export function parseCommandInvocation(value: string, catalog: SessionCommand[]): CommandInvocation | undefined {
  const token = value.match(commandPattern)?.[0]
  if (!token) return undefined
  const command = catalog.find(item => item.name === token)
  if (!command) return undefined
  const rest = value.slice(token.length)
  return { name: command.name, arguments: /^\s/.test(rest) ? rest.slice(1) : rest }
}
