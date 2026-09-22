import { createHash, randomBytes, randomUUID } from "node:crypto"
import { chmod, mkdir, open, readFile, rename, unlink } from "node:fs/promises"
import { createServer, type Server } from "node:http"
import { spawn } from "node:child_process"
import { platform } from "node:os"
import { resolve } from "node:path"
import { setTimeout as delay } from "node:timers/promises"
import { home } from "./profiles.js"

const clientId = "app_EMoamEEZ73f0CkXaXp7hrann"
const authorizeUrl = "https://auth.openai.com/oauth/authorize"
const tokenUrl = "https://auth.openai.com/oauth/token"
const redirectUri = "http://localhost:1455/auth/callback"
const scope = "openid profile email offline_access api.connectors.read api.connectors.invoke"
const authClaim = "https://api.openai.com/auth"
const profileClaim = "https://api.openai.com/profile"

export type CodexCredential = {
  type: "oauth"; access: string; refresh: string; expires: number
  accountId: string; accountUserId?: string; email?: string
}

type TokenIdentity = Pick<CodexCredential, "accountId"> & Partial<Pick<CodexCredential, "accountUserId" | "email">>
type LoginOptions = {
  signal?: AbortSignal
  onAuth: (url: string) => void
  onProgress?: (message: string) => void
  onManualCodeInput?: () => Promise<string>
  openBrowser?: boolean
}

function jwt(token: string): Record<string, unknown> | undefined {
  try {
    const parts = token.split(".")
    if (parts.length !== 3) return
    return JSON.parse(Buffer.from(parts[1]!, "base64url").toString("utf8")) as Record<string, unknown>
  } catch { return }
}
function record(value: unknown): Record<string, unknown> | undefined {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : undefined
}
function tokenIdentity(access: string, idToken?: string): TokenIdentity {
  const accessPayload = jwt(access), idPayload = idToken ? jwt(idToken) : undefined
  const auth = record(accessPayload?.[authClaim]) ?? record(idPayload?.[authClaim])
  const profile = record(accessPayload?.[profileClaim]) ?? record(idPayload?.[profileClaim])
  const accountId = auth?.chatgpt_account_id
  if (typeof accountId !== "string" || !accountId) throw new Error("codex token has no ChatGPT account id")
  const accountUserId = auth?.chatgpt_account_user_id
  const email = profile?.email
  return {
    accountId,
    ...(typeof accountUserId === "string" && accountUserId ? { accountUserId } : {}),
    ...(typeof email === "string" && email.trim() ? { email: email.trim().toLowerCase() } : {}),
  }
}

export function parseAuthorizationInput(input: string): { code?: string; state?: string } {
  const value = input.trim()
  if (!value) return {}
  try {
    const url = new URL(value)
    return { code: url.searchParams.get("code") ?? undefined, state: url.searchParams.get("state") ?? undefined }
  } catch {}
  if (value.includes("#")) { const [code, state] = value.split("#", 2); return { code, state } }
  if (value.includes("code=")) {
    const params = new URLSearchParams(value)
    return { code: params.get("code") ?? undefined, state: params.get("state") ?? undefined }
  }
  return { code: value }
}

export function createAuthorization(): { verifier: string; state: string; url: string } {
  const verifier = randomBytes(96).toString("base64url")
  const challenge = createHash("sha256").update(verifier).digest("base64url")
  const state = randomBytes(16).toString("hex")
  const url = new URL(authorizeUrl)
  for (const [key, value] of Object.entries({
    response_type: "code", client_id: clientId, redirect_uri: redirectUri, scope,
    code_challenge: challenge, code_challenge_method: "S256", state,
    id_token_add_organizations: "true", codex_cli_simplified_flow: "true", originator: "albedo",
  })) url.searchParams.set(key, value)
  return { verifier, state, url: url.toString() }
}

async function exchange(code: string, verifier: string, signal?: AbortSignal): Promise<CodexCredential> {
  const response = await fetch(tokenUrl, {
    method: "POST", headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams({ grant_type: "authorization_code", client_id: clientId, code, code_verifier: verifier, redirect_uri: redirectUri }),
    redirect: "error", signal: AbortSignal.any([...(signal ? [signal] : []), AbortSignal.timeout(15_000)]),
  })
  if (!response.ok) {
    const body = (await response.text().catch(() => "")).slice(0, 4096)
    throw new Error(`codex token exchange failed (${response.status})${body ? `: ${body}` : ""}`)
  }
  const value = await response.json() as { access_token?: unknown; refresh_token?: unknown; expires_in?: unknown; id_token?: unknown }
  if (typeof value.access_token !== "string" || typeof value.refresh_token !== "string" ||
      typeof value.expires_in !== "number" || value.expires_in <= 0)
    throw new Error("codex token exchange response is incomplete")
  return {
    type: "oauth", access: value.access_token, refresh: value.refresh_token,
    expires: Date.now() + value.expires_in * 1000,
    ...tokenIdentity(value.access_token, typeof value.id_token === "string" ? value.id_token : undefined),
  }
}

function browser(url: string): void {
  const [command, args] = platform() === "darwin" ? ["open", [url]]
    : platform() === "win32" ? ["cmd", ["/c", "start", "", url]] : ["xdg-open", [url]]
  const child = spawn(command, args, { detached: true, stdio: "ignore" })
  child.on("error", () => {})
  child.unref()
}

function callbackServer(state: string, signal?: AbortSignal): Promise<{ server: Server; code: Promise<string> }> {
  return new Promise((resolveServer, reject) => {
    let settle!: (code: string) => void
    let fail!: (error: Error) => void
    const code = new Promise<string>((resolve, rejectCode) => { settle = resolve; fail = rejectCode })
    const server = createServer((req, res) => {
      const url = new URL(req.url ?? "", "http://localhost")
      res.setHeader("content-type", "text/html; charset=utf-8")
      if (url.pathname !== "/auth/callback") { res.statusCode = 404; res.end("callback route not found"); return }
      if (url.searchParams.get("state") !== state) { res.statusCode = 400; res.end("state mismatch"); return }
      const value = url.searchParams.get("code")
      if (!value) { res.statusCode = 400; res.end("missing authorization code"); return }
      res.end("OpenAI authentication completed. You can close this window.")
      settle(value)
    })
    const abort = () => fail(new Error("codex login cancelled"))
    signal?.addEventListener("abort", abort, { once: true })
    server.once("error", error => { signal?.removeEventListener("abort", abort); reject(error) })
    server.listen(1455, "127.0.0.1", () => resolveServer({ server, code }))
  })
}

export async function loginCodex(options: LoginOptions): Promise<CodexCredential> {
  const auth = createAuthorization()
  const { server, code: callback } = await callbackServer(auth.state, options.signal)
  try {
    options.onAuth(auth.url)
    options.onProgress?.("waiting for browser authorization")
    if (options.openBrowser !== false) browser(auth.url)
    const sources = [callback]
    if (options.onManualCodeInput) sources.push(options.onManualCodeInput().then(input => {
      const parsed = parseAuthorizationInput(input)
      if (parsed.state && parsed.state !== auth.state) throw new Error("oauth state mismatch")
      if (!parsed.code) throw new Error("missing authorization code")
      return parsed.code
    }))
    const code = await Promise.race(sources)
    options.onProgress?.("exchanging authorization code")
    return await exchange(code, auth.verifier, options.signal)
  } finally { server.close() }
}

export function credentialIdentity(credential: CodexCredential): string {
  return credential.accountUserId ? `account-user:${credential.accountUserId}`
    : credential.accountId ? `account:${credential.accountId}`
    : credential.email ? `email:${credential.email.toLowerCase()}`
    : `refresh:${createHash("sha256").update(credential.refresh).digest("hex").slice(0, 16)}`
}

async function authData(directory: string): Promise<Record<string, unknown>> {
  try {
    const value: unknown = JSON.parse(await readFile(resolve(directory, "auth.json"), "utf8"))
    const data = record(value)
    if (!data) throw new Error()
    return data
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return {}
    throw new Error("invalid credential store in auth.json; repair it before logging in")
  }
}

function parseCodexAccounts(entry: unknown): CodexCredential[] {
  const values = Array.isArray(entry) ? entry : entry === undefined ? [] : [entry]
  if (!values.every(value => {
    const item = record(value)
    return item?.type === "oauth" && typeof item.access === "string" && item.access.length > 0 &&
      typeof item.refresh === "string" && item.refresh.length > 0 && typeof item.expires === "number" &&
      Number.isFinite(item.expires) && typeof item.accountId === "string" && item.accountId.length > 0 &&
      (item.accountUserId === undefined || typeof item.accountUserId === "string") &&
      (item.email === undefined || typeof item.email === "string")
  })) throw new Error("invalid openai-codex credentials in auth.json; repair them before logging in")
  return values as CodexCredential[]
}

export async function codexAccounts(directory = home): Promise<CodexCredential[]> {
  return parseCodexAccounts((await authData(directory))["openai-codex"])
}

export async function saveCodexAccount(credential: CodexCredential, directory = home): Promise<void> {
  await mkdir(directory, { recursive: true, mode: 0o700 }); await chmod(directory, 0o700)
  const lock = resolve(directory, "auth.lock")
  let owner
  for (let attempt = 0; ; attempt++) {
    try { owner = await open(lock, "wx", 0o600); break }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "EEXIST" || attempt === 99) throw error
      await delay(20)
    }
  }
  const temporary = resolve(directory, `auth.${randomUUID()}.tmp`)
  try {
    const data = await authData(directory)
    const accounts = parseCodexAccounts(data["openai-codex"])
    const identity = credentialIdentity(credential)
    const index = accounts.findIndex(account => credentialIdentity(account) === identity)
    if (index >= 0) accounts[index] = credential; else accounts.push(credential)
    const next = { ...data, "openai-codex": accounts.length === 1 ? accounts[0] : accounts }
    const file = await open(temporary, "wx", 0o600)
    try { await file.writeFile(JSON.stringify(next, null, 2) + "\n"); await file.sync() }
    finally { await file.close() }
    await rename(temporary, resolve(directory, "auth.json"))
  } finally { await unlink(temporary).catch(() => {}); await owner?.close(); await unlink(lock).catch(() => {}) }
}
