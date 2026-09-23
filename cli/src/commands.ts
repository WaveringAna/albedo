export type CommandArgument = {
  name: string
  description: string
  required: boolean
  choices?: string[]
}

export type SessionCommand = {
  name: string
  description: string
  method: string
  arguments: CommandArgument[]
  modelCallable: boolean
  userTurn: boolean
  /** Opens as the extension's own page when run bare; older daemons omit it. */
  page?: boolean
}

export type CommandInvocation = {
  name: string
  arguments: string
}

export type CommandMenuItem = { name: string; description: string }

/** Required finite arguments are shown as complete, runnable menu entries. */
export function commandMenuItems(catalog: SessionCommand[]): CommandMenuItem[] {
  return catalog.flatMap(command => {
    const argument = command.arguments[0]
    return argument?.required && argument.choices?.length
      ? argument.choices.map(choice => ({ name: `${command.name} ${choice}`, description: argument.description }))
      : [{ name: command.name, description: command.description }]
  })
}

const commandToken = /^\/[^\s]+/

const commandPattern = /^\/[^\s]+$/

const methodPattern = /^[A-Za-z_][A-Za-z0-9_]*$/

function parseCommand(item: unknown): SessionCommand | undefined {
  if (!item || typeof item !== "object") return undefined
  const command = item as Partial<SessionCommand>
  const args = command.arguments
  const validArgs = Array.isArray(args) && args.every(argument => {
    if (!argument || typeof argument !== "object") return false
    const item = argument as Partial<CommandArgument>
    return typeof item.name === "string" && typeof item.description === "string" &&
      typeof item.required === "boolean" &&
      (item.choices === undefined || (Array.isArray(item.choices) && item.choices.every(choice => typeof choice === "string")))
  })
  if (typeof command.name !== "string" || !commandPattern.test(command.name) ||
      typeof command.description !== "string" ||
      typeof command.method !== "string" || !methodPattern.test(command.method) ||
      !validArgs ||
      typeof command.modelCallable !== "boolean" || typeof command.userTurn !== "boolean" ||
      (command.page !== undefined && typeof command.page !== "boolean"))
    return undefined
  return command as SessionCommand
}

/** One malformed row must not blank the menu; valid entries survive it. */
export function parseCommandCatalog(value: unknown): SessionCommand[] {
  if (!Array.isArray(value)) throw new Error("daemon returned invalid command catalog")
  const commands = value.map(parseCommand).filter((item): item is SessionCommand => item !== undefined)
  if (value.length > 0 && commands.length === 0) throw new Error("daemon returned invalid command metadata")
  return commands
}

/** Built-ins run first in App; this resolves only exact daemon-assigned commands. */
export function parseCommandInvocation(value: string, catalog: SessionCommand[]): CommandInvocation | undefined {
  const token = value.match(commandToken)?.[0]
  if (!token) return undefined
  const command = catalog.find(item => item.name === token)
  if (!command) return undefined
  const rest = value.slice(token.length)
  return { name: command.name, arguments: /^\s/.test(rest) ? rest.slice(1) : rest }
}
