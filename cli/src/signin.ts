import { spawn } from "node:child_process"
import { platform } from "node:os"
import { setTimeout as delay } from "node:timers/promises"

import { request, type Connection } from "./daemon.js"
import type { Protocol } from "./profiles.js"

/** A sign-in the daemon can run, and one account it has stored for that provider. */
export type Login = { provider: string; label: string; detail: string; protocol: Protocol }
export type Account = { provider: string; id: string; label: string; detail: string; selected: boolean }
export type SignIns = { logins: Login[]; accounts: Account[] }
export type SignInStatus = { state: "waiting" | "exchanging" | "done" | "failed"; message: string }
export type StartedSignIn = { id: string; url: string }

const pollIntervalMs = 300
const loginPath = (id: string): string => `/auth/logins/${encodeURIComponent(id)}`
const accountPath = (provider: string, id: string): string => `/auth/${encodeURIComponent(provider)}/accounts/${encodeURIComponent(id)}`
const array = <T>(value: unknown): T[] => Array.isArray(value) ? value as T[] : []

export const signIns = async (connection: Connection): Promise<SignIns> => {
  const value = await request<Partial<SignIns>>(connection, "/auth")
  return { logins: array(value?.logins), accounts: array(value?.accounts) }
}
export const startSignIn = (connection: Connection, provider: string): Promise<StartedSignIn> =>
  request(connection, `/auth/${encodeURIComponent(provider)}`, {})
export const signInStatus = (connection: Connection, id: string): Promise<SignInStatus> =>
  request(connection, loginPath(id))
export const provideSignInInput = (connection: Connection, id: string, input: string): Promise<unknown> =>
  request(connection, loginPath(id), { input })
export const cancelSignIn = (connection: Connection, id: string): Promise<unknown> =>
  request(connection, loginPath(id), undefined, "DELETE")
export const selectAccount = (connection: Connection, provider: string, id: string): Promise<unknown> =>
  request(connection, accountPath(provider, id), {})
export const removeAccount = (connection: Connection, provider: string, id: string): Promise<unknown> =>
  request(connection, accountPath(provider, id), undefined, "DELETE")

/** Reports every status until the sign-in settles, or the signal ends the watch. */
export async function pollSignIn(
  connection: Connection, id: string, onStatus: (status: SignInStatus) => void, signal?: AbortSignal,
): Promise<SignInStatus | undefined> {
  for (;;) {
    if (signal?.aborted) return
    const status = await signInStatus(connection, id)
    if (signal?.aborted) return
    onStatus(status)
    if (status.state === "done" || status.state === "failed") return status
    try { await delay(pollIntervalMs, undefined, { signal }) } catch { return }
  }
}

type Spawned = { on: (event: "error", listener: () => void) => unknown; unref: () => void }
export type Launcher = (command: string, args: string[], options: { detached: true; stdio: "ignore" }) => Spawned

const launch: Launcher = (command, args, options) => {
  const child = spawn(command, args, options)
  child.on("error", () => {})
  child.unref()
  return child
}

export function openBrowser(url: string, opener: Launcher = launch): void {
  if (process.env.ALBEDO_NO_BROWSER) return
  const [command, args]: [string, string[]] = platform() === "darwin" ? ["open", [url]]
    : platform() === "win32" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]]
  opener(command, args, { detached: true, stdio: "ignore" })
}
