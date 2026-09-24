import { spawn } from "node:child_process"
import { randomBytes } from "node:crypto"
import { mkdir, readFile, unlink, open, chmod } from "node:fs/promises"
import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"
import { setTimeout as delay } from "node:timers/promises"

import { home } from "./profiles.js"
export type Connection = { port: number; token: string; pid: number; version: number }
export type Session = { id: string; title?: string; last_assistant_at?: number | null; workspace: string; model: string; protocol: string; provider: string }
const record = resolve(home, "daemon.json")
export async function request<T>(connection: Connection, path: string, body?: unknown, method?: "GET" | "POST" | "DELETE"): Promise<T> {
  const response = await fetch(`http://127.0.0.1:${connection.port}${path}`, {
    method: method ?? (body === undefined ? "GET" : "POST"), redirect: "error", signal: AbortSignal.timeout(20_000),
    headers: { authorization: `Bearer ${connection.token}`, "content-type": "application/json" },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const value = await response.json() as { error?: string }
  if (!response.ok) throw new Error(value.error ?? `HTTP ${response.status}`)
  return value as T
}
export async function existing(): Promise<Connection | undefined> {
  try {
    const connection = JSON.parse(await readFile(record,"utf8")) as Connection
    if (!Number.isInteger(connection.port) || connection.port < 1 || connection.port > 65535 || typeof connection.token !== "string" || ![1, 2].includes(connection.version)) return
    const response = await fetch(`http://127.0.0.1:${connection.port}/health`, { headers: { authorization: `Bearer ${connection.token}` }, signal: AbortSignal.timeout(500), redirect: "error" })
    if (response.ok && (await response.json() as { version?: number }).version === connection.version) return connection
  } catch {}
  return
}
function compatible(connection: Connection): Connection {
  if (connection.version !== 2) throw new Error("an older daemon is running; when its work is finished, run albedo daemon --stop, then start albedo again")
  return connection
}
export async function ensure(): Promise<Connection> {
  const current = await existing()
  if (current) return compatible(current)
  await mkdir(home,{ recursive:true,mode:0o700 })
  await chmod(home,0o700)
  const lock = resolve(home,"starting.lock")
  let owner
  try { owner = await open(lock,"wx",0o600) } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error
    for (let attempt=0; attempt<300; attempt++) { const running = await existing(); if (running) return compatible(running); await delay(100) }
    throw new Error(`daemon startup timed out; inspect ${home}/daemon.log; remove ${lock} if its starter is no longer running`)
  }
  try {
    const again = await existing()
    if (again) return compatible(again)
    const log = await open(resolve(home,"daemon.log"),"a",0o600)
    const root = resolve(dirname(fileURLToPath(import.meta.url)),"../..")
    const env = Object.fromEntries(Object.entries(process.env).filter(([name]) => !["ALBEDO_API_KEY", "ALBEDO_MODEL", "ALBEDO_BASE_URL", "ALBEDO_PROTOCOL"].includes(name)))
    const child = spawn("gleam",["run"],{ cwd:root, detached:true, stdio:["ignore",log.fd,log.fd],env:{ ...env,ALBEDO_HOME:home,ALBEDO_TOKEN:randomBytes(32).toString("hex") } })
    let failure: Error | undefined
    child.on("error",error => { failure=error })
    child.unref()
    await log.close()
    for (let attempt=0; attempt<300; attempt++) {
      if (failure) throw failure
      if (child.exitCode !== null) throw new Error(`daemon exited; inspect ${home}/daemon.log`)
      const running=await existing()
      if (running) return compatible(running)
      await delay(100)
    }
    throw new Error(`daemon startup timed out; inspect ${home}/daemon.log`)
  } finally { await owner.close(); await unlink(lock).catch(() => {}) }
}
