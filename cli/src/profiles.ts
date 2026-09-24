import { randomUUID } from "node:crypto"
import { chmod, mkdir, open, readFile, rename, unlink } from "node:fs/promises"
import { homedir } from "node:os"
import { resolve } from "node:path"

export const home = resolve(process.env.ALBEDO_HOME ?? `${homedir()}/.albedo`)
export type Protocol = "responses" | "chat_completions"
export type OpenAISettings = { extension?: "openai"; baseUrl: string; apiKey: string; model: string; protocol: Protocol }
/** A profile whose credentials the daemon owns for that provider extension. */
export type SignInSettings = { extension: string; model: string; protocol: Protocol; baseUrl?: never; apiKey?: never }
export type Settings = OpenAISettings | SignInSettings
export type Profiles = { active?: string; providers: Record<string, Settings> }
const object = (value: unknown): value is Record<string, unknown> => !!value && typeof value === "object" && !Array.isArray(value)
export function providerName(value: string): string {
  const name = value.trim()
  if (!/^[a-zA-Z0-9][a-zA-Z0-9._-]{0,63}$/.test(name)) throw new Error("name must be 1–64 letters, numbers, dots, underscores or hyphens")
  return name
}
export function endpoint(value: string): string {
  let url: URL
  try { url = new URL(value.trim()) } catch { throw new Error("enter an http or https api base url") }
  if (!["https:", "http:"].includes(url.protocol) || url.username || url.password || url.search || url.hash)
    throw new Error("use an http or https base url without credentials, query or fragment")
  return url.href.replace(/\/+$/, "")
}
function model(value: unknown): string {
  if (typeof value !== "string" || !value.trim() || value.length > 512 || /[\x00-\x1f\x7f]/.test(value))
    throw new Error("provider needs a model id of 1–512 characters")
  return value.trim()
}
function settings(value: unknown): Settings {
  if (!object(value)) throw new Error("provider settings must be an object")
  if (value.extension !== undefined && value.extension !== "openai") {
    if (typeof value.extension !== "string") throw new Error("provider settings need a text extension")
    const extension = providerName(value.extension)
    if (extension === "codex" && value.protocol !== "responses") throw new Error("codex requires the responses protocol")
    if (value.protocol !== "responses" && value.protocol !== "chat_completions")
      throw new Error(`${extension} requires the responses or chat completions protocol`)
    return { extension, model: model(value.model), protocol: value.protocol }
  }
  if (typeof value.baseUrl !== "string" ||
      typeof value.apiKey !== "string" || !value.apiKey || /[\s\x00-\x1f\x7f]/.test(value.apiKey) ||
      (value.protocol !== "responses" && value.protocol !== "chat_completions"))
    throw new Error("openai provider needs an endpoint, api key, model and valid protocol")
  return { extension: "openai", baseUrl: endpoint(value.baseUrl), apiKey: value.apiKey,
    model: model(value.model), protocol: value.protocol }
}
export async function profiles(directory = home): Promise<Profiles> {
  let text: string
  try { text = await readFile(resolve(directory, "config.json"), "utf8") }
  catch (error) { if ((error as NodeJS.ErrnoException).code === "ENOENT") return { providers: {} }; throw error }
  try {
    const value: unknown = JSON.parse(text)
    if (!object(value)) throw new Error()
    // Preserve the previous single-provider file without accepting environment overrides.
    if (!("providers" in value)) return { active: "default", providers: { default: settings(value) } }
    if (!object(value.providers)) throw new Error()
    const providers = Object.fromEntries(Object.entries(value.providers).map(([name, value]) => [providerName(name), settings(value)]))
    if (value.active !== undefined && (typeof value.active !== "string" || !Object.hasOwn(providers, value.active))) throw new Error()
    return { providers, ...(typeof value.active === "string" ? { active: value.active } : {}) }
  } catch { throw new Error("invalid provider configuration in config.json; repair it before logging in") }
}
export async function saveProvider(name: string, value: Settings, directory = home): Promise<void> {
  name = providerName(name)
  value = settings(value)
  await mkdir(directory, { recursive: true, mode: 0o700 })
  await chmod(directory, 0o700)
  const lock = resolve(directory, "config.lock")
  let owner
  try { owner = await open(lock, "wx", 0o600) }
  catch (error) {
    if ((error as NodeJS.ErrnoException).code === "EEXIST") throw new Error("another login is saving; retry, or remove config.lock if that process has stopped")
    throw error
  }
  const temporary = resolve(directory, `config.${randomUUID()}.tmp`)
  try {
    const saved = await profiles(directory)
    const file = await open(temporary, "wx", 0o600)
    try {
      await file.writeFile(JSON.stringify({ active: name, providers: { ...saved.providers, [name]: value } }, null, 2) + "\n")
      await file.sync()
    } finally { await file.close() }
    await rename(temporary, resolve(directory, "config.json"))
  } finally { await unlink(temporary).catch(() => {}); await owner.close(); await unlink(lock) }
}
